import AppKit
import AgentMonitorShared
import Combine
import CoreServices
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class MonitorRuntime: ObservableObject {
    let store = SessionStore()
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var integrationsInstalled = false
    @Published private(set) var integrationMessage: String?
    private var server: SocketServer?
    private var timer: Timer?
    private var desktopSessionFallbackTimer: Timer?
    private var desktopSessionObserver: CodexSessionDirectoryObserver?
    private let desktopSessionWatcher = CodexDesktopSessionWatcher()
    private var overlay: OverlayController?

    func start() {
        guard server == nil else { return }
        UserDefaults.standard.register(defaults: [
            "overlayEnabled": true,
            "showReadyInOverlay": true,
            "overlayRetentionMinutes": 5,
            "overlayDensity": OverlayDensity.standard.rawValue,
            "menuBarDensity": MenuBarDensity.standard.rawValue,
            "showTerminalInMenuBar": true,
            "readyRetentionMinutes": 15,
            "speechEnabled": false,
            "speakOnCompletion": true,
            "speechVoice": SpeechService.systemDefaultVoice
        ])
        store.reconcileProcesses()
        startDesktopSessionMonitoring()
        refreshLaunchAtLoginStatus()
        refreshIntegrationStatus()
        let server = SocketServer { [weak self] event in
            Task { @MainActor in
                self?.store.apply(event)
                self?.refreshOverlay()
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            store.showMessage(error.localizedDescription)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.reconcileProcesses()
                self?.refreshOverlay()
            }
        }
        desktopSessionFallbackTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanDesktopSessions() }
        }
        refreshOverlay()
    }

    func stop() {
        timer?.invalidate()
        desktopSessionFallbackTimer?.invalidate()
        desktopSessionObserver?.stop()
        desktopSessionObserver = nil
        server?.stop()
        overlay?.close()
    }

    func refreshOverlay() {
        store.refreshDisplay()
        guard UserDefaults.standard.bool(forKey: "overlayEnabled") else {
            overlay?.close()
            overlay = nil
            return
        }
        if overlay == nil {
            overlay = OverlayController(store: store) { [weak self] in
                self?.refreshOverlay()
            }
        }
        overlay?.updateVisibility(hasSessions: !store.overlaySessions.isEmpty)
    }

    private func applyDesktopSessionEvents(_ events: [MonitorEvent]) {
        guard !events.isEmpty else { return }
        for event in events { store.apply(event) }
        refreshOverlay()
    }

    private func startDesktopSessionMonitoring() {
        let observer = CodexSessionDirectoryObserver(rootURL: desktopSessionWatcher.sessionsRoot) { [weak self] urls in
            Task { @MainActor in self?.scanDesktopSessions(changedURLs: urls) }
        }
        observer.start()
        desktopSessionObserver = observer
        scanDesktopSessions()
    }

    private func scanDesktopSessions(changedURLs: [URL]? = nil) {
        let terminal = Self.detectCodexDesktopHost()
        Task { [weak self, desktopSessionWatcher] in
            let events = await desktopSessionWatcher.poll(changedURLs: changedURLs, terminal: terminal)
            guard let self, !Task.isCancelled else { return }
            self.applyDesktopSessionEvents(events)
        }
    }

    private static func detectCodexDesktopHost() -> TerminalHost {
        let bundleIdentifier = "com.openai.codex"
        let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        return TerminalHost(
            kind: .unknown,
            bundleIdentifier: bundleIdentifier,
            hostPid: application?.processIdentifier,
            agentPid: application?.processIdentifier,
            processStartedAt: application?.launchDate
        )
    }

    func requestNotifications(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "notificationsEnabled")
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted { UserDefaults.standard.set(false, forKey: "notificationsEnabled") }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            store.showMessage("Could not update Launch at Login: \(error.localizedDescription)")
        }
        refreshLaunchAtLoginStatus()
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agent-monitor-helper")
    }

    func installIntegrations() -> Bool {
        do {
            try HookConfigurationService.install(helperURL: helperURL)
            integrationsInstalled = true
            integrationMessage = "Codex and Claude Code integrations are installed."
            return true
        } catch {
            integrationMessage = "Could not install integrations: \(error.localizedDescription)"
            return false
        }
    }

    func removeIntegrations() {
        do {
            try HookConfigurationService.remove()
            integrationsInstalled = false
            integrationMessage = "Agent integrations were removed."
        } catch {
            integrationMessage = "Could not remove integrations: \(error.localizedDescription)"
        }
    }

    func refreshIntegrationStatus() {
        integrationsInstalled = HookConfigurationService.isInstalled(helperURL: helperURL)
    }

    private func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled || status == .requiresApproval
        launchAtLoginNeedsApproval = status == .requiresApproval
    }
}

actor CodexDesktopSessionWatcher {
    private struct Metadata {
        let sessionID: String
        let cwd: String
    }

    private struct FileState {
        let metadata: Metadata
        var offset: UInt64
        var remainder = Data()
        var lastLifecycle: Lifecycle?
        var lastModifiedAt: Date
    }

    private struct Lifecycle {
        enum Kind: String {
            case started = "task_started"
            case completed = "task_complete"
            case aborted = "turn_aborted"
        }

        let kind: Kind
        let turnID: String?
        let occurredAt: Date
    }

    nonisolated let sessionsRoot: URL
    private var files: [URL: FileState] = [:]
    private var lastDiscoveryAt: Date?

    init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    ) {
        self.sessionsRoot = sessionsRoot.resolvingSymlinksInPath()
    }

    func poll(
        now: Date = Date(),
        changedURLs: [URL]? = nil,
        terminal: TerminalHost
    ) -> [MonitorEvent] {
        var events: [MonitorEvent] = []
        let candidates: Set<URL>
        if let changedURLs {
            candidates = Set(jsonFiles(from: changedURLs, modifiedAfter: now.addingTimeInterval(-5)))
        } else {
            candidates = Set(discoverRecentlyModifiedFiles(now: now)).union(files.keys)
        }
        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else {
                files.removeValue(forKey: url)
                continue
            }
            if files[url] == nil {
                if let (state, activeLifecycle) = bootstrap(url: url, now: now) {
                    files[url] = state
                    if let activeLifecycle {
                        events.append(makeEvent(
                            activeLifecycle,
                            metadata: state.metadata,
                            transcriptURL: url,
                            terminal: terminal
                        ))
                    }
                }
            } else {
                events.append(contentsOf: readAppendedEvents(from: url, now: now, terminal: terminal))
            }
        }
        if changedURLs == nil {
            files = files.filter { _, state in
                state.lastLifecycle?.kind == .started || now.timeIntervalSince(state.lastModifiedAt) < 24 * 60 * 60
            }
        }
        return events.sorted { $0.occurredAt < $1.occurredAt }
    }

    private func jsonFiles(from urls: [URL], modifiedAfter cutoff: Date) -> [URL] {
        var result: [URL] = []
        for url in urls {
            if url.pathExtension == "jsonl" {
                result.append(url.resolvingSymlinksInPath())
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }
            for case let child as URL in enumerator where child.pathExtension == "jsonl" {
                guard let values = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt >= cutoff else { continue }
                result.append(child.resolvingSymlinksInPath())
            }
        }
        return result
    }

    private func discoverRecentlyModifiedFiles(now: Date) -> [URL] {
        let cutoff = lastDiscoveryAt?.addingTimeInterval(-1) ?? now.addingTimeInterval(-24 * 60 * 60)
        lastDiscoveryAt = now
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= cutoff else { continue }
            result.append(url.resolvingSymlinksInPath())
        }
        return result
    }

    private func bootstrap(url: URL, now: Date) -> (FileState, Lifecycle?)? {
        guard let metadata = readMetadata(from: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        let modifiedAt = attributes[.modificationDate] as? Date ?? now
        let snapshot = readLatestLifecycle(from: url, fileSize: size)
        let state = FileState(
            metadata: metadata,
            offset: size,
            remainder: snapshot.remainder,
            lastLifecycle: snapshot.lifecycle,
            lastModifiedAt: modifiedAt
        )
        return (state, snapshot.lifecycle?.kind == .started ? snapshot.lifecycle : nil)
    }

    private func readMetadata(from url: URL) -> Metadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        for line in data.split(separator: 0x0A).prefix(8) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let originator = payload["originator"] as? String,
                  originator.caseInsensitiveCompare("Codex Desktop") == .orderedSame,
                  let sessionID = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String else { continue }
            let isSubagent = payload["thread_source"] as? String == "subagent"
                || (payload["source"] as? [String: Any])?["subagent"] != nil
            guard !isSubagent else { return nil }
            return Metadata(sessionID: sessionID, cwd: cwd)
        }
        return nil
    }

    private func readLatestLifecycle(from url: URL, fileSize: UInt64) -> (lifecycle: Lifecycle?, remainder: Data) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, Data()) }
        defer { try? handle.close() }
        let maximumTailSize: UInt64 = 8 * 1024 * 1024
        let start = fileSize > maximumTailSize ? fileSize - maximumTailSize : 0
        do {
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            let remainder: Data
            if data.last == 0x0A {
                remainder = Data()
                if lines.last?.isEmpty == true { lines.removeLast() }
            } else if let last = lines.last,
                      (try? JSONSerialization.jsonObject(with: Data(last))) != nil {
                remainder = Data()
            } else {
                remainder = Data(lines.popLast() ?? Data.SubSequence())
            }
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            for line in lines.reversed() {
                if let lifecycle = decodeLifecycle(Data(line)) { return (lifecycle, remainder) }
            }
            return (nil, remainder)
        } catch {
            return (nil, Data())
        }
    }

    private func readAppendedEvents(from url: URL, now: Date, terminal: TerminalHost) -> [MonitorEvent] {
        guard var state = files[url],
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return [] }
        if size < state.offset {
            files.removeValue(forKey: url)
            guard let (newState, activeLifecycle) = bootstrap(url: url, now: now) else { return [] }
            files[url] = newState
            return activeLifecycle.map {
                [makeEvent($0, metadata: newState.metadata, transcriptURL: url, terminal: terminal)]
            } ?? []
        }
        guard size > state.offset,
              let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: state.offset)
            let appended = try handle.readToEnd() ?? Data()
            state.offset = size
            state.lastModifiedAt = attributes[.modificationDate] as? Date ?? now
            var combined = state.remainder
            combined.append(appended)
            var lines = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
            if combined.last == 0x0A {
                state.remainder.removeAll(keepingCapacity: true)
                if lines.last?.isEmpty == true { lines.removeLast() }
            } else if let last = lines.last,
                      (try? JSONSerialization.jsonObject(with: Data(last))) != nil {
                state.remainder.removeAll(keepingCapacity: true)
            } else {
                state.remainder = Data(lines.popLast() ?? Data.SubSequence())
            }

            var events: [MonitorEvent] = []
            for line in lines {
                guard let lifecycle = decodeLifecycle(Data(line)),
                      lifecycle.kind != state.lastLifecycle?.kind
                        || lifecycle.turnID != state.lastLifecycle?.turnID else { continue }
                state.lastLifecycle = lifecycle
                events.append(makeEvent(
                    lifecycle,
                    metadata: state.metadata,
                    transcriptURL: url,
                    terminal: terminal
                ))
            }
            files[url] = state
            return events
        } catch {
            return []
        }
    }

    private func decodeLifecycle(_ data: Data) -> Lifecycle? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let rawKind = payload["type"] as? String,
              let kind = Lifecycle.Kind(rawValue: rawKind) else { return nil }
        let occurredAt = (object["timestamp"] as? String).flatMap(Self.parseTimestamp) ?? Date()
        return Lifecycle(kind: kind, turnID: payload["turn_id"] as? String, occurredAt: occurredAt)
    }

    private func makeEvent(
        _ lifecycle: Lifecycle,
        metadata: Metadata,
        transcriptURL: URL,
        terminal: TerminalHost
    ) -> MonitorEvent {
        let eventType: MonitorEventType
        let status: SessionStatus
        switch lifecycle.kind {
        case .started:
            eventType = .userPromptSubmit
            status = .running
        case .completed:
            eventType = .agentTurnComplete
            status = .ready
        case .aborted:
            eventType = .stop
            status = .stale
        }
        return MonitorEvent(
            provider: .codex,
            eventId: "desktop:\(metadata.sessionID):\(lifecycle.turnID ?? String(lifecycle.occurredAt.timeIntervalSince1970)):\(lifecycle.kind.rawValue)",
            eventType: eventType,
            occurredAt: lifecycle.occurredAt,
            sessionId: metadata.sessionID,
            turnId: lifecycle.turnID,
            cwd: metadata.cwd,
            transcriptPath: transcriptURL.path,
            status: status,
            terminal: terminal
        )
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

}

private final class CodexSessionDirectoryObserver: @unchecked Sendable {
    private let rootURL: URL
    private let handler: @Sendable ([URL]) -> Void
    private let queue = DispatchQueue(label: "com.agentmonitor.codex-session-events", qos: .utility)
    private var stream: FSEventStreamRef?

    init(rootURL: URL, handler: @escaping @Sendable ([URL]) -> Void) {
        self.rootURL = rootURL
        self.handler = handler
    }

    func start() {
        guard stream == nil, FileManager.default.fileExists(atPath: rootURL.path) else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    private func receive(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        handler(urls)
    }

    private static let callback: FSEventStreamCallback = { _, context, _, eventPaths, _, _ in
        guard let context else { return }
        let observer = Unmanaged<CodexSessionDirectoryObserver>.fromOpaque(context).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        observer.receive(paths)
    }
}
