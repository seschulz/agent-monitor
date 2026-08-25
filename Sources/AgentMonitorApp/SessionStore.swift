import AppKit
import AVFoundation
import Combine
import AgentMonitorShared
import Foundation
import UserNotifications

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionRecord] = []
    @Published var lastMessage: String?
    @Published private(set) var displayDate = Date()
    var onCompletion: (() -> Void)?

    private var seenEventIDs = Set<String>()
    private var messageClearTask: Task<Void, Never>?
    private var persistenceErrorMessage: String?
    private let persistenceURL: URL
    private let defaults: UserDefaults
    private var readyRetention: TimeInterval {
        let minutes = defaults.integer(forKey: "readyRetentionMinutes")
        return TimeInterval(max(minutes, 1) * 60)
    }
    private var overlayRetention: TimeInterval {
        let minutes = defaults.integer(forKey: "overlayRetentionMinutes")
        return TimeInterval(max(minutes, 1) * 60)
    }

    init(baseDirectory: URL = AppPaths.baseDirectory, defaults: UserDefaults = .standard) {
        persistenceURL = baseDirectory.appendingPathComponent("sessions.json")
        self.defaults = defaults
        load()
    }

    var visibleSessions: [SessionRecord] {
        sessions.filter { ($0.status == .running || $0.status == .ready) && $0.dismissedAt == nil }.sorted {
            if $0.status.sortPriority == $1.status.sortPriority { return $0.updatedAt > $1.updatedAt }
            return $0.status.sortPriority < $1.status.sortPriority
        }
    }

    var overlaySessions: [SessionRecord] {
        overlaySessions(at: displayDate)
    }

    func overlaySessions(at date: Date) -> [SessionRecord] {
        visibleSessions.filter { session in
            if session.status == .running { return true }
            guard session.status == .ready && defaults.bool(forKey: "showReadyInOverlay") else {
                return false
            }
            return date.timeIntervalSince(session.updatedAt) < overlayRetention
        }
    }

    func apply(_ event: MonitorEvent) {
        guard !seenEventIDs.contains(event.eventId) else { return }
        seenEventIDs.insert(event.eventId)
        if seenEventIDs.count > 10_000 { seenEventIDs.removeAll(keepingCapacity: true) }

        let sessionID = event.scopedSessionID
        if event.eventType == .postToolUse,
           sessions.first(where: { $0.id == sessionID })?.status == .stale {
            return
        }
        // Codex Stop means the turn is no longer active, including when the
        // user interrupts it. A final notify remains authoritative if it has
        // already arrived for this turn.
        if event.provider == .codex, event.eventType == .stop,
           let existing = sessions.first(where: { $0.id == sessionID }),
           existing.completedAt != nil,
           event.turnId == nil || event.turnId == existing.currentTurnId {
            return
        }
        if Self.isCompletion(event),
           let existing = sessions.first(where: { $0.id == sessionID }),
           existing.completedAt != nil,
           event.turnId == nil || event.turnId == existing.currentTurnId {
            return
        }
        let previousStatus = sessions.first(where: { $0.id == sessionID })?.status
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            guard event.occurredAt >= sessions[index].updatedAt else { return }
            let advancesTurn = event.eventType == .userPromptSubmit
                || event.eventType == .agentTurnComplete
                || event.eventType == .stop
            let isNewTurn = advancesTurn && event.turnId != nil && event.turnId != sessions[index].currentTurnId
            if event.eventType == .userPromptSubmit {
                sessions[index].dismissedAt = nil
                sessions[index].completedAt = nil
            }
            if advancesTurn {
                sessions[index].currentTurnId = event.turnId ?? sessions[index].currentTurnId
            }
            sessions[index].status = event.status
            sessions[index].provider = event.provider
            sessions[index].cwd = event.cwd
            if event.eventType == .sessionStart || event.eventType == .userPromptSubmit {
                sessions[index].transcriptPath = event.transcriptPath ?? sessions[index].transcriptPath
            }
            sessions[index].displayName = displayName(for: event.cwd)
            sessions[index].terminal = event.terminal
            sessions[index].updatedAt = event.occurredAt
            sessions[index].attentionReason = event.attentionReason
            if isNewTurn {
                sessions[index].completedAt = nil
                if event.status != .attention { sessions[index].attentionReason = nil }
            }
            if event.status == .ready { sessions[index].completedAt = event.occurredAt }
        } else {
            sessions.append(SessionRecord(event: event))
        }
        prune()
        persist()
        let isDismissed = sessions.first(where: { $0.id == sessionID })?.dismissedAt != nil
        if !isDismissed && Self.shouldSpeakCompletion(for: event, previousStatus: previousStatus) {
            onCompletion?()
            notify(title: displayName(for: event.cwd), body: "\(event.provider.displayName) is ready")
        }
        if !isDismissed,
           Self.shouldSpeakCompletion(for: event, previousStatus: previousStatus) {
            speak("\(event.provider.displayName) finished", enabledBy: "speakOnCompletion")
        }
    }

    nonisolated static func shouldSpeakCompletion(for event: MonitorEvent, previousStatus: SessionStatus?) -> Bool {
        isCompletion(event) && (previousStatus == .running || previousStatus == .stale)
    }

    nonisolated static func isCompletion(_ event: MonitorEvent) -> Bool {
        event.provider == .claude
            ? event.eventType == .stop
            : event.eventType == .agentTurnComplete
    }

    func dismiss(_ id: String, at date: Date = Date()) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].dismissedAt = date
        persist()
    }

    func dismiss(_ ids: Set<String>, at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        var changed = false
        for index in sessions.indices where ids.contains(sessions[index].id) {
            sessions[index].dismissedAt = date
            changed = true
        }
        if changed { persist() }
    }

    func clearAll() {
        sessions.removeAll()
        persist()
    }

    func reconcileProcesses() {
        let now = Date()
        displayDate = now
        var changed = false
        for index in sessions.indices where sessions[index].status == .running {
            if sessions[index].provider == .codex,
               Self.transcriptShowsInterruption(sessions[index]) {
                sessions[index].status = .stale
                sessions[index].updatedAt = now
                changed = true
                continue
            }
            guard let pid = sessions[index].terminal.agentPid, pid > 0 else { continue }
            if Self.agentProcessIsInactive(pid) {
                sessions[index].status = .stale
                sessions[index].updatedAt = now
                changed = true
            }
        }
        prune()
        if changed { persist() }
    }

    nonisolated static func agentProcessIsInactive(_ pid: Int32) -> Bool {
        if kill(pid, 0) != 0 { return errno == ESRCH }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let count = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard count == size else { return false }
        return info.pbi_status == UInt32(SSTOP) || info.pbi_status == UInt32(SZOMB)
    }

    nonisolated private static func transcriptShowsInterruption(_ session: SessionRecord) -> Bool {
        guard let path = session.transcriptPath,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            let length = try handle.seekToEnd()
            try handle.seek(toOffset: length > 128 * 1024 ? length - 128 * 1024 : 0)
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8) else { return false }
            for line in text.split(separator: "\n").reversed() {
                guard let lineData = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                let payload = object["payload"] as? [String: Any] ?? object
                guard payload["type"] as? String == "turn_aborted" else { continue }
                let turnID = payload["turn_id"] as? String
                return session.currentTurnId == nil || turnID == session.currentTurnId
            }
        } catch {
            return false
        }
        return false
    }

    func refreshDisplay() {
        displayDate = Date()
        prune()
    }

    func showMessage(_ message: String) {
        messageClearTask?.cancel()
        lastMessage = message
        messageClearTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            if self.lastMessage == message { self.lastMessage = nil }
        }
    }

    private func displayName(for cwd: String) -> String {
        let value = URL(fileURLWithPath: cwd).lastPathComponent
        return value.isEmpty ? "Agent session" : value
    }

    private func prune() {
        let now = Date()
        sessions.removeAll { session in
            if session.status == .attention { return true }
            if let dismissedAt = session.dismissedAt {
                return now.timeIntervalSince(dismissedAt) > 24 * 60 * 60
            }
            if session.status == .closed { return now.timeIntervalSince(session.updatedAt) > 60 }
            if session.status == .ready { return now.timeIntervalSince(session.completedAt ?? session.updatedAt) > readyRetention }
            return session.status == .stale && now.timeIntervalSince(session.updatedAt) > 24 * 60 * 60
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            sessions = try JSONDecoder.monitorDecoder.decode([SessionRecord].self, from: Data(contentsOf: persistenceURL))
            prune()
        } catch {
            let backup = persistenceURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: persistenceURL, to: backup)
            sessions = []
            lastMessage = "Session history was unreadable and moved aside."
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder.monitorEncoder.encode(sessions)
            try data.write(to: persistenceURL, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: persistenceURL.path)
            if let persistenceErrorMessage {
                if lastMessage == persistenceErrorMessage {
                    messageClearTask?.cancel()
                    lastMessage = nil
                }
                self.persistenceErrorMessage = nil
            }
        } catch {
            guard persistenceErrorMessage == nil else { return }
            let message = "Could not save session history: \(error.localizedDescription)"
            persistenceErrorMessage = message
            showMessage(message)
        }
    }

    private func notify(title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func speak(_ phrase: String, enabledBy eventSetting: String) {
        guard defaults.bool(forKey: "speechEnabled"), defaults.bool(forKey: eventSetting) else { return }
        SpeechService.speak(phrase, voice: defaults.string(forKey: "speechVoice"))
    }
}

enum SpeechService {
    static let systemDefaultVoice = "System Default"

    static let availableVoices: [String] = {
        let names = AVSpeechSynthesisVoice.speechVoices().map(\.name)
        return [systemDefaultVoice] + Array(Set(names)).sorted()
    }()

    static func speak(_ phrase: String, voice: String?) {
        let selectedVoice = voice ?? systemDefaultVoice
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = selectedVoice == systemDefaultVoice
                ? [phrase]
                : ["-v", selectedVoice, phrase]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }
}

private extension SessionStatus {
    var sortPriority: Int {
        switch self {
        case .attention: 0
        case .running: 1
        case .ready: 2
        case .stale: 3
        case .closed: 4
        }
    }
}
