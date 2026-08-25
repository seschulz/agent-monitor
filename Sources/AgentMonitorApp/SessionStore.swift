import AppKit
import AVFoundation
import Combine
import AgentMonitorShared
import Foundation
import UserNotifications

enum DiagnosticEventOutcome: String, Codable, Sendable {
    case applied
    case ignoredDuplicate
    case ignoredStaleSession
    case ignoredCompletedTurn
    case ignoredOutOfOrder

    var label: String {
        switch self {
        case .applied: "Applied"
        case .ignoredDuplicate: "Ignored: duplicate"
        case .ignoredStaleSession: "Ignored: stale session"
        case .ignoredCompletedTurn: "Ignored: completed turn"
        case .ignoredOutOfOrder: "Ignored: out of order"
        }
    }
}

struct DiagnosticTimelineEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let receivedAt: Date
    let event: MonitorEvent
    let previousStatus: SessionStatus?
    let resultingStatus: SessionStatus?
    let outcome: DiagnosticEventOutcome
    let completionSignalEmitted: Bool
    let notificationTriggered: Bool
    let speechTriggered: Bool

    init(
        id: UUID = UUID(),
        receivedAt: Date = Date(),
        event: MonitorEvent,
        previousStatus: SessionStatus?,
        resultingStatus: SessionStatus?,
        outcome: DiagnosticEventOutcome,
        completionSignalEmitted: Bool = false,
        notificationTriggered: Bool = false,
        speechTriggered: Bool = false
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.event = event
        self.previousStatus = previousStatus
        self.resultingStatus = resultingStatus
        self.outcome = outcome
        self.completionSignalEmitted = completionSignalEmitted
        self.notificationTriggered = notificationTriggered
        self.speechTriggered = speechTriggered
    }

    var sessionID: String { event.scopedSessionID }
}

struct DiagnosticSessionSummary: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let provider: AgentProvider
    let eventCount: Int
    let updatedAt: Date
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var diagnosticEvents: [DiagnosticTimelineEntry] = []
    @Published var lastMessage: String?
    @Published private(set) var displayDate = Date()
    var onCompletion: (() -> Void)?

    private var seenEventIDs = Set<String>()
    private var messageClearTask: Task<Void, Never>?
    private var persistenceErrorMessage: String?
    private let persistenceURL: URL
    private let diagnosticPersistenceURL: URL
    private let defaults: UserDefaults
    private let capturesDiagnostics: Bool
    private static let diagnosticRetention: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumDiagnosticEventsPerSession = 100
    private static let maximumDiagnosticEvents = 1_000
    private var readyRetention: TimeInterval {
        let minutes = defaults.integer(forKey: "readyRetentionMinutes")
        return TimeInterval(max(minutes, 1) * 60)
    }
    private var overlayRetention: TimeInterval {
        let minutes = defaults.integer(forKey: "overlayRetentionMinutes")
        return TimeInterval(max(minutes, 1) * 60)
    }

    init(
        baseDirectory: URL = AppPaths.baseDirectory,
        defaults: UserDefaults = .standard,
        diagnosticsEnabled: Bool? = nil
    ) {
        persistenceURL = baseDirectory.appendingPathComponent("sessions.json")
        diagnosticPersistenceURL = baseDirectory.appendingPathComponent("diagnostics.json")
        self.defaults = defaults
        capturesDiagnostics = diagnosticsEnabled
            ?? (defaults.bool(forKey: "internalDiagnosticsEnabled")
                || ProcessInfo.processInfo.arguments.contains("--internal-diagnostics"))
        load()
        if capturesDiagnostics { loadDiagnostics() }
    }

    var diagnosticsEnabled: Bool { capturesDiagnostics }

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
        let sessionID = event.scopedSessionID
        let previousStatus = sessions.first(where: { $0.id == sessionID })?.status
        guard !seenEventIDs.contains(event.eventId) else {
            recordDiagnostic(event, previousStatus: previousStatus, outcome: .ignoredDuplicate)
            return
        }
        seenEventIDs.insert(event.eventId)
        if seenEventIDs.count > 10_000 { seenEventIDs.removeAll(keepingCapacity: true) }

        if event.eventType == .postToolUse,
           sessions.first(where: { $0.id == sessionID })?.status == .stale {
            recordDiagnostic(event, previousStatus: previousStatus, outcome: .ignoredStaleSession)
            return
        }
        // Codex Stop means the turn is no longer active, including when the
        // user interrupts it. A final notify remains authoritative if it has
        // already arrived for this turn.
        if event.provider == .codex, event.eventType == .stop,
           let existing = sessions.first(where: { $0.id == sessionID }),
           existing.completedAt != nil,
           event.turnId == nil || event.turnId == existing.currentTurnId {
            recordDiagnostic(event, previousStatus: previousStatus, outcome: .ignoredCompletedTurn)
            return
        }
        if Self.isCompletion(event),
           let existing = sessions.first(where: { $0.id == sessionID }),
           existing.completedAt != nil,
           event.turnId == nil || event.turnId == existing.currentTurnId {
            recordDiagnostic(event, previousStatus: previousStatus, outcome: .ignoredCompletedTurn)
            return
        }
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            guard event.occurredAt >= sessions[index].updatedAt else {
                recordDiagnostic(event, previousStatus: previousStatus, outcome: .ignoredOutOfOrder)
                return
            }
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
        let emitsCompletionSignal = !isDismissed
            && Self.shouldSpeakCompletion(for: event, previousStatus: previousStatus)
        recordDiagnostic(
            event,
            previousStatus: previousStatus,
            resultingStatus: sessions.first(where: { $0.id == sessionID })?.status,
            outcome: .applied,
            completionSignalEmitted: emitsCompletionSignal,
            notificationTriggered: emitsCompletionSignal && defaults.bool(forKey: "notificationsEnabled"),
            speechTriggered: emitsCompletionSignal
                && defaults.bool(forKey: "speechEnabled")
                && defaults.bool(forKey: "speakOnCompletion")
        )
        if emitsCompletionSignal {
            onCompletion?()
            notify(title: displayName(for: event.cwd), body: "\(event.provider.displayName) is ready")
        }
        if emitsCompletionSignal {
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
        diagnosticEvents.removeAll()
        persist()
        persistDiagnostics()
    }

    var diagnosticSessionSummaries: [DiagnosticSessionSummary] {
        Dictionary(grouping: diagnosticEvents, by: \.sessionID).compactMap { sessionID, entries in
            guard let latest = entries.max(by: { $0.receivedAt < $1.receivedAt }) else { return nil }
            let name = URL(fileURLWithPath: latest.event.cwd).lastPathComponent
            return DiagnosticSessionSummary(
                id: sessionID,
                displayName: name.isEmpty ? "Agent session" : name,
                provider: latest.event.provider,
                eventCount: entries.count,
                updatedAt: latest.receivedAt
            )
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func diagnosticEntries(for sessionID: String) -> [DiagnosticTimelineEntry] {
        diagnosticEvents
            .filter { $0.sessionID == sessionID }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    func diagnosticJSON(for sessionID: String) -> String? {
        let entries = diagnosticEntries(for: sessionID).reversed()
        guard let data = try? JSONEncoder.monitorEncoder.encode(Array(entries)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func clearDiagnostics(for sessionID: String) {
        diagnosticEvents.removeAll { $0.sessionID == sessionID }
        persistDiagnostics()
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

    private func recordDiagnostic(
        _ event: MonitorEvent,
        previousStatus: SessionStatus?,
        resultingStatus: SessionStatus? = nil,
        outcome: DiagnosticEventOutcome,
        completionSignalEmitted: Bool = false,
        notificationTriggered: Bool = false,
        speechTriggered: Bool = false
    ) {
        guard capturesDiagnostics else { return }
        diagnosticEvents.append(DiagnosticTimelineEntry(
            event: event,
            previousStatus: previousStatus,
            resultingStatus: resultingStatus ?? previousStatus,
            outcome: outcome,
            completionSignalEmitted: completionSignalEmitted,
            notificationTriggered: notificationTriggered,
            speechTriggered: speechTriggered
        ))
        pruneDiagnostics()
        persistDiagnostics()
    }

    private func pruneDiagnostics(now: Date = Date()) {
        diagnosticEvents.removeAll {
            now.timeIntervalSince($0.receivedAt) > Self.diagnosticRetention
        }

        var counts: [String: Int] = [:]
        var retained: [DiagnosticTimelineEntry] = []
        for entry in diagnosticEvents.reversed() {
            let count = counts[entry.sessionID, default: 0]
            guard count < Self.maximumDiagnosticEventsPerSession else { continue }
            counts[entry.sessionID] = count + 1
            retained.append(entry)
            if retained.count == Self.maximumDiagnosticEvents { break }
        }
        diagnosticEvents = retained.reversed()
    }

    private func loadDiagnostics() {
        guard FileManager.default.fileExists(atPath: diagnosticPersistenceURL.path),
              let data = try? Data(contentsOf: diagnosticPersistenceURL),
              let entries = try? JSONDecoder.monitorDecoder.decode([DiagnosticTimelineEntry].self, from: data) else {
            return
        }
        diagnosticEvents = entries
        pruneDiagnostics()
    }

    private func persistDiagnostics() {
        guard capturesDiagnostics else {
            try? FileManager.default.removeItem(at: diagnosticPersistenceURL)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: diagnosticPersistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder.monitorEncoder.encode(diagnosticEvents)
            try data.write(to: diagnosticPersistenceURL, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: diagnosticPersistenceURL.path
            )
        } catch {
            // Diagnostics are intentionally best-effort and must never affect monitoring.
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
