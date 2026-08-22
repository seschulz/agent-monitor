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
        let previousStatus = sessions.first(where: { $0.id == sessionID })?.status
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            guard event.occurredAt >= sessions[index].updatedAt else { return }
            let isNewTurn = event.turnId != nil && event.turnId != sessions[index].currentTurnId
            if event.eventType == .userPromptSubmit {
                sessions[index].dismissedAt = nil
            }
            sessions[index].currentTurnId = event.turnId ?? sessions[index].currentTurnId
            sessions[index].status = event.status
            sessions[index].provider = event.provider
            sessions[index].cwd = event.cwd
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
        if !isDismissed && (event.eventType == .agentTurnComplete || event.eventType == .stop) && previousStatus != .ready {
            onCompletion?()
            notify(title: displayName(for: event.cwd), body: "\(event.provider.displayName) is ready")
        }
        if !isDismissed,
           Self.shouldSpeakCompletion(for: event, previousStatus: previousStatus) {
            speak("\(event.provider.displayName) finished", enabledBy: "speakOnCompletion")
        }
    }

    nonisolated static func shouldSpeakCompletion(for event: MonitorEvent, previousStatus: SessionStatus?) -> Bool {
        if event.provider == .claude {
            return event.eventType == .stop
        }
        return (event.eventType == .stop || event.eventType == .agentTurnComplete) && previousStatus != .ready
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
        for index in sessions.indices where sessions[index].status != .closed && sessions[index].status != .stale {
            guard let pid = sessions[index].terminal.agentPid, pid > 0 else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                sessions[index].status = .stale
                sessions[index].updatedAt = now
            }
        }
        prune()
        persist()
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
