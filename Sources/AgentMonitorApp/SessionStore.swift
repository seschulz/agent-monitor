import AppKit
import AVFoundation
import Combine
import AgentMonitorShared
import Foundation
import UserNotifications

enum DiagnosticEventOutcome: String, Codable, Sendable {
    case applied
    case ignoredWaitingForInput
    case ignoredPermissionAlertsDisabled
    case ignoredDuplicate
    case ignoredStaleSession
    case ignoredCompletedTurn
    case ignoredOutOfOrder

    var label: String {
        switch self {
        case .applied: "Applied"
        case .ignoredWaitingForInput: "Ignored: waiting for input"
        case .ignoredPermissionAlertsDisabled: "Ignored: permission alerts disabled"
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
    var onAttention: (() -> Void)?

    private struct PendingCompletion {
        let event: MonitorEvent
        let task: Task<Void, Never>
    }
    private var pendingCompletions: [String: PendingCompletion] = [:]
    private let completionAlertDelay: Duration
    private let speechOutput: (String, String?) -> Void
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
        completionAlertDelay: Duration = .milliseconds(750),
        baseDirectory: URL = AppPaths.baseDirectory,
        defaults: UserDefaults = .standard,
        diagnosticsEnabled: Bool? = nil,
        speechOutput: @escaping (String, String?) -> Void = { SpeechService.speak($0, voice: $1) }
    ) {
        persistenceURL = baseDirectory.appendingPathComponent("sessions.json")
        diagnosticPersistenceURL = baseDirectory.appendingPathComponent("diagnostics.json")
        self.defaults = defaults
        self.completionAlertDelay = completionAlertDelay
        self.speechOutput = speechOutput
        AlertPreferences.migrate(defaults)
        capturesDiagnostics = diagnosticsEnabled
            ?? (defaults.bool(forKey: "internalDiagnosticsEnabled")
                || ProcessInfo.processInfo.arguments.contains("--internal-diagnostics"))
        load()
        if capturesDiagnostics { loadDiagnostics() }
        clearDisabledPermissionAttention()
    }

    var diagnosticsEnabled: Bool { capturesDiagnostics }

    func setPermissionAlertsEnabled(_ enabled: Bool, for provider: AgentProvider) {
        defaults.set(enabled, forKey: AlertPreferences.permissionKey(for: provider))
        clearDisabledPermissionAttention()
    }

    private func clearDisabledPermissionAttention() {
        var changed = false
        for index in sessions.indices where sessions[index].status == .attention
            && sessions[index].attentionReason == "Waiting for permission"
            && !AlertPreferences.permissionEnabled(for: sessions[index].provider, defaults: defaults) {
            sessions[index].status = .running
            sessions[index].attentionReason = nil
            sessions[index].attentionToolUseID = nil
            changed = true
        }
        if changed { persist() }
    }

    var visibleSessions: [SessionRecord] {
        sessions.filter { ($0.status == .running || $0.status == .ready || $0.status == .attention) && $0.dismissedAt == nil }.sorted {
            if $0.status.sortPriority == $1.status.sortPriority { return $0.updatedAt > $1.updatedAt }
            return $0.status.sortPriority < $1.status.sortPriority
        }
    }

    var overlaySessions: [SessionRecord] {
        overlaySessions(at: displayDate)
    }

    func overlaySessions(at date: Date) -> [SessionRecord] {
        visibleSessions.filter { session in
            if session.status == .running || session.status == .attention { return true }
            guard session.status == .ready && defaults.bool(forKey: "showReadyInOverlay") else {
                return false
            }
            return date.timeIntervalSince(session.updatedAt) < overlayRetention
        }
    }

    func apply(_ event: MonitorEvent) {
        apply(event, deferringCompletion: true)
    }

    private func apply(_ event: MonitorEvent, deferringCompletion: Bool) {
        let sessionID = event.scopedSessionID
        let previousStatus = sessions.first(where: { $0.id == sessionID })?.status
        guard !seenEventIDs.contains(event.eventId) else {
            recordDiagnostic(event, previousStatus: previousStatus, outcome: .ignoredDuplicate)
            return
        }
        // Permission review can be handled by another agent. When disabled,
        // leave the current lifecycle (including real input waits) untouched.
        if event.eventType == .permissionRequested, !AlertPreferences.permissionEnabled(for: event.provider, defaults: defaults) {
            recordDiagnostic(event, previousStatus: previousStatus, outcome: .ignoredPermissionAlertsDisabled)
            return
        }
        // Questions remain active until their tool response, a new prompt,
        // an interruption, or session end. Stop/notify can race the question.
        if let existing = sessions.first(where: { $0.id == sessionID }),
           existing.status == .attention, existing.attentionReason == "Waiting for input",
           Self.isCompletion(event) || event.eventType == .stop {
            recordDiagnostic(event, previousStatus: previousStatus, outcome: .ignoredWaitingForInput)
            return
        }
        // Hold completion itself briefly: this also prevents a ready-state
        // flash when the question hook arrives just after the finish hook.
        if deferringCompletion, completionAlertDelay > .zero,
           Self.shouldSpeakCompletion(for: event, previousStatus: previousStatus) {
            if pendingCompletions[sessionID] != nil { return }
            let delay = completionAlertDelay
            let task = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, self.pendingCompletions[sessionID]?.event.eventId == event.eventId else { return }
                self.pendingCompletions.removeValue(forKey: sessionID)
                self.apply(event, deferringCompletion: false)
            }
            pendingCompletions[sessionID] = PendingCompletion(event: event, task: task)
            return
        }
        seenEventIDs.insert(event.eventId)
        if seenEventIDs.count > 10_000 { seenEventIDs.removeAll(keepingCapacity: true) }

        if let existing = sessions.first(where: { $0.id == sessionID }) {
            // Claude emits a generic permission notification for question
            // dialogs too. Preserve the more specific tool-derived state.
            if existing.status == .attention, existing.attentionReason == "Waiting for input",
               event.eventType == .permissionRequested, event.toolName == nil, event.toolUseID == nil {
                recordDiagnostic(event, previousStatus: previousStatus, outcome: .ignoredDuplicate)
                return
            }
            // A late callback from another turn must not resurrect its prompt.
            if event.status == .attention,
               (event.turnId != nil && existing.currentTurnId != nil && event.turnId != existing.currentTurnId
                || existing.status == .ready && existing.completedAt != nil) {
                recordDiagnostic(event, previousStatus: previousStatus, outcome: .ignoredCompletedTurn)
                return
            }
            // A parallel tool finishing does not answer the pending question.
            if existing.status == .attention, event.eventType == .postToolUse,
               let waitingID = existing.attentionToolUseID, let toolID = event.toolUseID, waitingID != toolID {
                recordDiagnostic(event, previousStatus: previousStatus, outcome: .ignoredStaleSession)
                return
            }
        }

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
           existing.status == .ready,
           existing.completedAt != nil,
           event.turnId == nil || event.turnId == existing.currentTurnId {
            recordDiagnostic(event, previousStatus: previousStatus, outcome: .ignoredCompletedTurn)
            return
        }
        if Self.isCompletion(event),
           let existing = sessions.first(where: { $0.id == sessionID }),
           existing.status == .ready,
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
            if event.status == .attention || event.eventType == .userPromptSubmit
                || event.eventType == .postToolUse || event.eventType == .interrupt || event.eventType == .sessionEnd {
                cancelCompletion(for: sessionID)
            }
            let advancesTurn = event.eventType == .userPromptSubmit
                || event.eventType == .agentTurnComplete
                || event.eventType == .stop
                || event.eventType == .interrupt
                || event.status == .attention
            let isNewTurn = advancesTurn && event.turnId != nil && event.turnId != sessions[index].currentTurnId
            let preservesActiveTurn = event.eventType == .sessionStart
                && (sessions[index].status == .running || sessions[index].status == .attention)
            if event.eventType == .userPromptSubmit {
                sessions[index].dismissedAt = nil
                sessions[index].completedAt = nil
            }
            if event.status == .attention && previousStatus != .attention {
                sessions[index].dismissedAt = nil
                sessions[index].completedAt = nil
            }
            if advancesTurn {
                sessions[index].currentTurnId = event.turnId ?? sessions[index].currentTurnId
            }
            if !preservesActiveTurn {
                sessions[index].status = event.status
            }
            sessions[index].provider = event.provider
            sessions[index].cwd = event.cwd
            if event.eventType == .sessionStart || event.eventType == .userPromptSubmit {
                sessions[index].transcriptPath = event.transcriptPath ?? sessions[index].transcriptPath
            }
            sessions[index].displayName = displayName(for: event.cwd)
            sessions[index].terminal = event.terminal
            sessions[index].updatedAt = event.occurredAt
            if !preservesActiveTurn {
                sessions[index].attentionReason = event.attentionReason
                sessions[index].attentionToolUseID = event.status == .attention
                    ? event.toolUseID ?? sessions[index].attentionToolUseID : nil
            }
            if isNewTurn {
                sessions[index].completedAt = nil
                if event.status != .attention { sessions[index].attentionReason = nil }
            }
            if event.status == .ready && !preservesActiveTurn {
                sessions[index].completedAt = event.occurredAt
            }
        } else {
            sessions.append(SessionRecord(event: event))
        }
        prune()
        persist()
        let isDismissed = sessions.first(where: { $0.id == sessionID })?.dismissedAt != nil
        let emitsCompletionSignal = !isDismissed
            && Self.shouldSpeakCompletion(for: event, previousStatus: previousStatus)
        let emitsAttentionSignal = !isDismissed && event.status == .attention && previousStatus != .attention
        let attentionTrigger: AlertTrigger = event.eventType == .inputRequested ? .input : .permission
        recordDiagnostic(
            event,
            previousStatus: previousStatus,
            resultingStatus: sessions.first(where: { $0.id == sessionID })?.status,
            outcome: .applied,
            completionSignalEmitted: emitsCompletionSignal,
            notificationTriggered: (emitsCompletionSignal && defaults.bool(forKey: "notificationsEnabled"))
                || (emitsAttentionSignal && defaults.bool(forKey: attentionTrigger.notificationKey)),
            speechTriggered: defaults.bool(forKey: "speechEnabled")
                && ((emitsCompletionSignal && defaults.bool(forKey: "speakOnCompletion"))
                    || (emitsAttentionSignal && defaults.bool(forKey: attentionTrigger.speechKey)))
        )
        if emitsCompletionSignal {
            onCompletion?()
            notify(title: displayName(for: event.cwd), body: "\(event.provider.displayName) is ready")
        }
        if emitsCompletionSignal {
            speak(.finished, for: event)
        }
        if emitsAttentionSignal {
            onAttention?()
            speak(attentionTrigger, for: event)
            notify(title: "\(event.provider.displayName) needs your attention",
                   body: "\(displayName(for: event.cwd)) — \(event.attentionReason ?? "Waiting for you")",
                   preference: attentionTrigger.notificationKey)
        }
    }

    nonisolated static func shouldSpeakCompletion(for event: MonitorEvent, previousStatus: SessionStatus?) -> Bool {
        isCompletion(event) && (previousStatus == .running || previousStatus == .stale || previousStatus == .attention)
    }

    nonisolated static func isCompletion(_ event: MonitorEvent) -> Bool {
        event.provider == .claude
            ? event.eventType == .stop
            : event.eventType == .agentTurnComplete
    }

    private func cancelCompletion(for sessionID: String) {
        pendingCompletions.removeValue(forKey: sessionID)?.task.cancel()
    }

    func dismiss(_ id: String, at date: Date = Date()) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        cancelCompletion(for: id)
        sessions[index].dismissedAt = date
        persist()
    }

    func dismiss(_ ids: Set<String>, at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        var changed = false
        for index in sessions.indices where ids.contains(sessions[index].id) {
            cancelCompletion(for: sessions[index].id)
            sessions[index].dismissedAt = date
            changed = true
        }
        if changed { persist() }
    }

    func clearAll() {
        for completion in pendingCompletions.values { completion.task.cancel() }
        pendingCompletions.removeAll()
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
        for index in sessions.indices where sessions[index].status == .running || sessions[index].status == .attention {
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

    private func notify(title: String, body: String, preference: String = "notificationsEnabled") {
        guard defaults.bool(forKey: preference) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func speak(_ trigger: AlertTrigger, for event: MonitorEvent) {
        guard defaults.bool(forKey: "speechEnabled"), defaults.bool(forKey: trigger.speechKey) else { return }
        let phrase = SpeechMessageTemplate.render(
            defaults.string(forKey: trigger.templateKey) ?? trigger.defaultMessage,
            agent: event.provider.displayName,
            project: displayName(for: event.cwd),
            terminal: event.terminal.displayName,
            directory: event.cwd,
            fallback: trigger.defaultMessage
        )
        speechOutput(phrase, defaults.string(forKey: "speechVoice"))
    }
}

/// Each trigger owns its delivery settings and spoken message. Permission
/// triggers additionally respect the provider switch before reaching the store.
enum AlertTrigger: String, CaseIterable, Identifiable {
    case finished, input, permission
    var id: String { rawValue }
    var label: String {
        switch self {
        case .finished: "Finished"
        case .input: "Needs input"
        case .permission: "Permission"
        }
    }
    var title: String {
        switch self {
        case .finished: "Work is finished"
        case .input: "An agent has a question"
        case .permission: "Permission is requested"
        }
    }
    var detail: String {
        switch self {
        case .finished: "Know when an agent completes its turn."
        case .input: "Get an alert when an agent is waiting for your answer."
        case .permission: "Choose which agents should interrupt you for approval."
        }
    }
    var symbol: String {
        switch self {
        case .finished: "checkmark.circle"
        case .input: "questionmark.bubble"
        case .permission: "hand.raised"
        }
    }
    var speechKey: String {
        switch self {
        case .finished: "speakOnCompletion"
        case .input: "speakOnInput"
        case .permission: "speakOnPermission"
        }
    }
    var notificationKey: String {
        switch self {
        case .finished: "notificationsEnabled"
        case .input: "inputNotificationsEnabled"
        case .permission: "permissionNotificationsEnabled"
        }
    }
    var templateKey: String {
        switch self {
        case .finished: "speechCompletionTemplate"
        case .input: "speechInputTemplate"
        case .permission: "speechPermissionTemplate"
        }
    }
    var defaultMessage: String {
        switch self {
        case .finished: "{agent} finished"
        case .input: "{agent} needs your input"
        case .permission: "{agent} needs your permission"
        }
    }
}

enum AlertPreferences {
    static func permissionKey(for provider: AgentProvider) -> String {
        "\(provider.rawValue)PermissionAlertsEnabled"
    }

    static func permissionEnabled(for provider: AgentProvider, defaults: UserDefaults) -> Bool {
        let key = permissionKey(for: provider)
        return defaults.object(forKey: key) == nil ? provider == .claude : defaults.bool(forKey: key)
    }

    static func migrate(_ defaults: UserDefaults) {
        // The provider defaults intentionally replace the retired global switch.
        // Once a provider has an explicit preference, always preserve it.
        for provider in AgentProvider.allCases where defaults.object(forKey: permissionKey(for: provider)) == nil {
            defaults.set(provider == .claude, forKey: permissionKey(for: provider))
        }
        for trigger in [AlertTrigger.input, .permission] {
            if defaults.object(forKey: trigger.speechKey) == nil {
                defaults.set(defaults.object(forKey: "speakOnAttention") == nil || defaults.bool(forKey: "speakOnAttention"), forKey: trigger.speechKey)
            }
            if defaults.object(forKey: trigger.notificationKey) == nil {
                defaults.set(defaults.bool(forKey: "attentionNotificationsEnabled"), forKey: trigger.notificationKey)
            }
        }
    }
}

enum SpeechMessageTemplate {
    static let defaultValue = "{agent} finished"

    static func render(
        _ template: String,
        agent: String,
        project: String,
        terminal: String,
        directory: String,
        fallback: String = defaultValue
    ) -> String {
        let value = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = value.isEmpty ? fallback : value
        let replacements = [
            "{agent}": agent,
            "{project}": project,
            "{terminal}": terminal,
            "{directory}": directory
        ]
        return replacements.reduce(source) { result, replacement in
            result.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
    }
}

enum SpeechService {
    static let systemDefaultVoice = "System Default"

    static let availableVoices: [String] = {
        let names = AVSpeechSynthesisVoice.speechVoices().map(\.name)
        return [systemDefaultVoice] + Array(Set(names)).sorted()
    }()

    private static let playbackQueue = DispatchQueue(label: "AgentMonitor.speech", qos: .utility)

    static func speak(_ phrase: String, voice: String?) {
        let selectedVoice = voice ?? systemDefaultVoice
        playbackQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = selectedVoice == systemDefaultVoice
                ? [phrase]
                : ["-v", selectedVoice, phrase]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                NSLog("Agent Monitor could not start speech: %@", error.localizedDescription)
            }
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
