import AppKit
import Foundation
import Testing
import AgentMonitorShared
@testable import AgentMonitorApp

@Test func nativeIntegrationSetupPreservesExistingHooksAndNotifyCommand() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent(".codex")
    let claude = root.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    let paths = HookConfigurationPaths(
        codexHooks: codex.appendingPathComponent("hooks.json"),
        codexConfig: codex.appendingPathComponent("config.toml"),
        claudeSettings: claude.appendingPathComponent("settings.json")
    )
    try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing-hook"}]}]}}"#
        .write(to: paths.codexHooks, atomically: true, encoding: .utf8)
    try #"notify = ["existing-notify", "--quiet"]"#
        .write(to: paths.codexConfig, atomically: true, encoding: .utf8)
    try #"{"hooks":{}}"#.write(to: paths.claudeSettings, atomically: true, encoding: .utf8)
    let helper = root.appendingPathComponent("Agent Monitor.app/Contents/MacOS/agent-monitor-helper")

    try HookConfigurationService.install(helperURL: helper, paths: paths)

    #expect(HookConfigurationService.isInstalled(helperURL: helper, paths: paths))
    #expect(try String(contentsOf: paths.codexHooks).contains("existing-hook"))
    #expect(try String(contentsOf: paths.codexHooks).contains(helper.path))
    #expect(try String(contentsOf: paths.claudeSettings).contains(helper.path))
    let dispatcher = codex.appendingPathComponent("bin/agent-monitor-notify")
    #expect(try String(contentsOf: dispatcher, encoding: .utf8).contains("existing-notify"))

    try HookConfigurationService.remove(paths: paths)

    #expect(!(try String(contentsOf: paths.codexHooks).contains("agent-monitor-helper")))
    #expect(!(try String(contentsOf: paths.claudeSettings).contains("agent-monitor-helper")))
    #expect(try String(contentsOf: paths.codexConfig).contains(#"notify = ["existing-notify","--quiet"]"#))
}

@Test func nativeIntegrationChainsCodexAppCompletionWithoutRecursion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent(".codex")
    let claude = root.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    let paths = HookConfigurationPaths(
        codexHooks: codex.appendingPathComponent("hooks.json"),
        codexConfig: codex.appendingPathComponent("config.toml"),
        claudeSettings: claude.appendingPathComponent("settings.json")
    )
    try #"notify = ["/Applications/SkyComputerUseClient", "turn-ended"]"#
        .write(to: paths.codexConfig, atomically: true, encoding: .utf8)
    try #"{"hooks":{}}"#.write(to: paths.codexHooks, atomically: true, encoding: .utf8)
    try #"{"hooks":{}}"#.write(to: paths.claudeSettings, atomically: true, encoding: .utf8)
    let helper = root.appendingPathComponent("Agent Monitor.app/Contents/MacOS/agent-monitor-helper")

    try HookConfigurationService.install(helperURL: helper, paths: paths)

    let installed = try String(contentsOf: paths.codexConfig, encoding: .utf8)
    #expect(installed.contains("SkyComputerUseClient"))
    #expect(installed.contains("--previous-notify"))
    #expect(installed.contains(helper.path))
    #expect(!installed.contains(#"\/Applications"#))
    #expect(!FileManager.default.fileExists(atPath: codex.appendingPathComponent("bin/agent-monitor-notify").path))

    try HookConfigurationService.install(helperURL: helper, paths: paths)
    #expect(try String(contentsOf: paths.codexConfig, encoding: .utf8) == installed)
}

@Test func elapsedSessionTimeFormatting() {
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(SessionRow.elapsedTime(from: start, to: start.addingTimeInterval(5)) == "0:05")
    #expect(SessionRow.elapsedTime(from: start, to: start.addingTimeInterval(754)) == "12:34")
    #expect(SessionRow.elapsedTime(from: start, to: start.addingTimeInterval(3_723)) == "1:02:03")
}

@MainActor
@Test func overlayPositionMovesBackFromDisconnectedDisplay() {
    let corrected = OverlayController.reachableTopLeft(
        NSPoint(x: 2_264, y: 444),
        windowSize: NSSize(width: 320, height: 160),
        visibleFrames: [NSRect(x: 0, y: 0, width: 1_440, height: 900)],
        preferredVisibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
    )

    #expect(corrected == NSPoint(x: 1_100, y: 444))
}

@MainActor
@Test func overlayPositionRemainsWhereItIsReachable() {
    let saved = NSPoint(x: 900, y: 700)
    let corrected = OverlayController.reachableTopLeft(
        saved,
        windowSize: NSSize(width: 320, height: 160),
        visibleFrames: [NSRect(x: 0, y: 0, width: 1_440, height: 900)],
        preferredVisibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
    )

    #expect(corrected == saved)
}

@Test func minimalOverlayTimeFormatting() {
    let start = Date(timeIntervalSince1970: 1_000)
    let ready = MonitorEvent(
        eventType: .agentTurnComplete,
        occurredAt: start,
        sessionId: "ready",
        cwd: "/tmp/repo",
        status: .ready,
        terminal: .init(kind: .unknown)
    )
    let session = SessionRecord(event: ready)

    #expect(SessionRow.minimalTime(for: session, at: start.addingTimeInterval(42)) == "42s")
    #expect(SessionRow.minimalTime(for: session, at: start.addingTimeInterval(125)) == "2m")
    #expect(SessionRow.minimalTime(for: session, at: start.addingTimeInterval(7_200)) == "2h")

    let running = SessionRecord(event: .init(
        eventType: .userPromptSubmit,
        occurredAt: start,
        sessionId: "running",
        cwd: "/tmp/repo",
        status: .running,
        terminal: .init(kind: .unknown)
    ))
    #expect(SessionRow.minimalTime(for: running, at: start.addingTimeInterval(42)) == "42s")
    #expect(SessionRow.minimalTime(for: running, at: start.addingTimeInterval(754)) == "12m")
    #expect(SessionRow.minimalTime(for: running, at: start.addingTimeInterval(58_119)) == "16h")
}

@Test func overlayDensityOffersFourIncreasingSizes() {
    #expect(OverlayDensity.allCases == [.minimal, .compact, .standard, .spacious])
    #expect(OverlayDensity.minimal.width < OverlayDensity.compact.width)
    #expect(OverlayDensity.compact.width < OverlayDensity.standard.width)
    #expect(OverlayDensity.standard.width < OverlayDensity.spacious.width)
    #expect(OverlayDensity.minimal.rowPadding < OverlayDensity.compact.rowPadding)
    #expect(OverlayDensity.compact.rowPadding < OverlayDensity.spacious.rowPadding)
}

@Test func menuBarDensityOffersThreeIncreasingSizes() {
    #expect(MenuBarDensity.compact.width < MenuBarDensity.standard.width)
    #expect(MenuBarDensity.standard.width < MenuBarDensity.spacious.width)
    #expect(MenuBarDensity.compact.rowPadding < MenuBarDensity.standard.rowPadding)
    #expect(MenuBarDensity.standard.rowPadding < MenuBarDensity.spacious.rowPadding)
    #expect(MenuBarDensity.compact.rowHeight < MenuBarDensity.standard.rowHeight)
    #expect(MenuBarDensity.standard.rowHeight < MenuBarDensity.spacious.rowHeight)
}

@Test func menuBarHeightShrinksWhenSessionsDisappear() {
    let fourRows = MenuContentView.contentHeight(sessionCount: 4, density: .standard)
    let oneRow = MenuContentView.contentHeight(sessionCount: 1, density: .standard)

    #expect(oneRow < fourRows)
    #expect(fourRows - oneRow == MenuBarDensity.standard.rowHeight * 3 + 3)
}

@Test func claudeSpeechOnlyRunsForStop() {
    let stop = MonitorEvent(
        provider: .claude,
        eventType: .stop,
        sessionId: "claude",
        cwd: "/tmp/repo",
        status: .ready,
        terminal: .init(kind: .unknown)
    )
    let sessionEnd = MonitorEvent(
        provider: .claude,
        eventType: .sessionEnd,
        sessionId: "claude",
        cwd: "/tmp/repo",
        status: .closed,
        terminal: .init(kind: .unknown)
    )

    #expect(SessionStore.shouldSpeakCompletion(for: stop, previousStatus: .running))
    #expect(!SessionStore.shouldSpeakCompletion(for: stop, previousStatus: .ready))
    #expect(!SessionStore.shouldSpeakCompletion(for: sessionEnd, previousStatus: .running))
}

@Test func codexCompletionSpeechBehaviorIsUnchanged() {
    let completion = MonitorEvent(
        provider: .codex,
        eventType: .agentTurnComplete,
        sessionId: "codex",
        cwd: "/tmp/repo",
        status: .ready,
        terminal: .init(kind: .unknown)
    )

    #expect(SessionStore.shouldSpeakCompletion(for: completion, previousStatus: .running))
    #expect(SessionStore.shouldSpeakCompletion(for: completion, previousStatus: .stale))
    #expect(!SessionStore.shouldSpeakCompletion(for: completion, previousStatus: .ready))
    #expect(!SessionStore.shouldSpeakCompletion(for: completion, previousStatus: nil))
}

@Test func completionSpeechTemplateExpandsSessionPlaceholders() {
    let phrase = CompletionSpeechTemplate.render(
        "{agent} finished {project} in {terminal} at {directory}",
        agent: "Claude",
        project: "agent-monitor",
        terminal: "Ghostty",
        directory: "/tmp/agent-monitor"
    )

    #expect(phrase == "Claude finished agent-monitor in Ghostty at /tmp/agent-monitor")
}

@Test func blankCompletionSpeechTemplateUsesDefaultMessage() {
    let phrase = CompletionSpeechTemplate.render(
        "   ",
        agent: "Codex",
        project: "agent-monitor",
        terminal: "Terminal",
        directory: "/tmp/agent-monitor"
    )

    #expect(phrase == "Codex finished")
}

@MainActor
@Test func ignoresDuplicatesAndOutOfOrderEvents() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory, diagnosticsEnabled: true)
    let now = Date()
    let running = MonitorEvent(eventId: "new", eventType: .userPromptSubmit, occurredAt: now, sessionId: "s", turnId: "t", cwd: "/tmp/repo", status: .running, terminal: .init(kind: .unknown))
    store.apply(running)
    store.apply(running)
    #expect(store.sessions.count == 1)
    let old = MonitorEvent(eventId: "old", eventType: .agentTurnComplete, occurredAt: now.addingTimeInterval(-1), sessionId: "s", turnId: "t", cwd: "/tmp/repo", status: .ready, terminal: .init(kind: .unknown))
    store.apply(old)
    #expect(store.sessions.first?.status == .running)
    #expect(store.diagnosticEntries(for: "codex:s").map(\.outcome) == [
        .ignoredOutOfOrder,
        .ignoredDuplicate,
        .applied
    ])
}

@MainActor
@Test func diagnosticTimelinePersistsRecentRawLifecycleEvents() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let event = MonitorEvent(
        eventId: "diagnostic-event",
        eventType: .postToolUse,
        occurredAt: now,
        sessionId: "diagnostic-session",
        turnId: "turn-1",
        cwd: "/tmp/diagnostic-project",
        status: .running,
        terminal: .init(kind: .ghostty, agentPid: 42, tty: "/dev/ttys001"),
        toolName: "shell"
    )

    SessionStore(baseDirectory: directory, diagnosticsEnabled: true).apply(event)
    let reloaded = SessionStore(baseDirectory: directory, diagnosticsEnabled: true)
    let entries = reloaded.diagnosticEntries(for: "codex:diagnostic-session")

    #expect(entries.count == 1)
    #expect(entries.first?.event.eventId == event.eventId)
    #expect(entries.first?.event.eventType == event.eventType)
    #expect(entries.first?.event.turnId == event.turnId)
    #expect(entries.first?.event.toolName == event.toolName)
    #expect(entries.first?.event.terminal == event.terminal)
    #expect(entries.first?.outcome == .applied)
    #expect(entries.first?.previousStatus == nil)
    #expect(entries.first?.resultingStatus == .running)
}

@MainActor
@Test func diagnosticTimelineIsBoundedPerSession() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(baseDirectory: directory, diagnosticsEnabled: true)
    let now = Date()

    for index in 0..<105 {
        store.apply(.init(
            eventId: "event-\(index)",
            eventType: .postToolUse,
            occurredAt: now.addingTimeInterval(TimeInterval(index)),
            sessionId: "bounded",
            turnId: "turn-1",
            cwd: "/tmp/project",
            status: .running,
            terminal: .init(kind: .unknown),
            toolName: "tool-\(index)"
        ))
    }

    let entries = store.diagnosticEntries(for: "codex:bounded")
    #expect(entries.count == 100)
    #expect(entries.first?.event.eventId == "event-104")
    #expect(entries.last?.event.eventId == "event-5")
}

@MainActor
@Test func diagnosticTimelineRecordsCompletionSignalAndDisabledEffects() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suiteName = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
    let store = SessionStore(baseDirectory: directory, defaults: defaults, diagnosticsEnabled: true)
    let now = Date()
    store.apply(.init(
        eventType: .userPromptSubmit,
        occurredAt: now,
        sessionId: "effects",
        cwd: "/tmp/project",
        status: .running,
        terminal: .init(kind: .unknown)
    ))
    store.apply(.init(
        eventType: .agentTurnComplete,
        occurredAt: now.addingTimeInterval(1),
        sessionId: "effects",
        cwd: "/tmp/project",
        status: .ready,
        terminal: .init(kind: .unknown)
    ))

    let completion = store.diagnosticEntries(for: "codex:effects").first
    #expect(completion?.completionSignalEmitted == true)
    #expect(completion?.notificationTriggered == false)
    #expect(completion?.speechTriggered == false)
}

@MainActor
@Test func diagnosticsRemainDisabledWithoutInternalOptIn() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(baseDirectory: directory, diagnosticsEnabled: false)
    store.apply(.init(
        eventType: .sessionStart,
        sessionId: "private",
        cwd: "/tmp/project",
        status: .running,
        terminal: .init(kind: .unknown)
    ))

    #expect(store.diagnosticEvents.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("diagnostics.json").path))
}

@MainActor
@Test func codexDesktopWatcherEmitsStartAndCompletionFromTranscript() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("rollout-desktop.jsonl")
    let metadata = #"{"type":"session_meta","payload":{"id":"desktop-session","cwd":"/tmp/desktop-project","originator":"Codex Desktop","thread_source":"user"}}"#
    let started = #"{"timestamp":"2026-08-25T17:00:00.123Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#
    try "\(metadata)\n\(started)\n".write(to: transcript, atomically: true, encoding: .utf8)
    let terminal = TerminalHost(kind: .unknown, bundleIdentifier: "com.openai.codex", hostPid: 123)
    let watcher = CodexDesktopSessionWatcher(sessionsRoot: root)

    let initial = await watcher.poll(terminal: terminal)
    #expect(initial.count == 1)
    #expect(initial.first?.eventType == .userPromptSubmit)
    #expect(initial.first?.status == .running)
    #expect(initial.first?.sessionId == "desktop-session")
    #expect(initial.first?.turnId == "turn-1")
    #expect(URL(fileURLWithPath: initial.first?.transcriptPath ?? "").resolvingSymlinksInPath()
        == transcript.resolvingSymlinksInPath())
    #expect(initial.first?.terminal == terminal)

    let completed = #"{"timestamp":"2026-08-25T17:01:00.456Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\(completed)\n".utf8))
    try handle.close()

    let update = await watcher.poll(
        now: Date().addingTimeInterval(2),
        changedURLs: [transcript],
        terminal: terminal
    )
    #expect(update.count == 1)
    #expect(update.first?.eventType == .agentTurnComplete)
    #expect(update.first?.status == .ready)
    #expect(update.first?.turnId == "turn-1")

    let secondTurn = #"{"timestamp":"2026-08-25T17:02:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}"#
    let aborted = #"{"timestamp":"2026-08-25T17:02:01.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-2"}}"#
    let secondHandle = try FileHandle(forWritingTo: transcript)
    try secondHandle.seekToEnd()
    try secondHandle.write(contentsOf: Data("\(secondTurn)\n\(aborted)\n".utf8))
    try secondHandle.close()

    let interruption = await watcher.poll(
        now: Date().addingTimeInterval(4),
        changedURLs: [transcript],
        terminal: terminal
    )
    #expect(interruption.map(\.eventType) == [.userPromptSubmit, .stop])
    #expect(interruption.map(\.status) == [.running, .stale])
}

@MainActor
@Test func codexDesktopWatcherIgnoresCLIAndCompletedHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cliTranscript = root.appendingPathComponent("rollout-cli.jsonl")
    let desktopTranscript = root.appendingPathComponent("rollout-completed.jsonl")
    let subagentTranscript = root.appendingPathComponent("rollout-subagent.jsonl")
    try """
    {"type":"session_meta","payload":{"id":"cli-session","cwd":"/tmp/cli","originator":"codex-tui","thread_source":"user"}}
    {"timestamp":"2026-08-25T17:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-cli"}}
    """.write(to: cliTranscript, atomically: true, encoding: .utf8)
    try """
    {"type":"session_meta","payload":{"id":"desktop-session","cwd":"/tmp/desktop","originator":"Codex Desktop","thread_source":"user"}}
    {"timestamp":"2026-08-25T17:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-done"}}
    {"timestamp":"2026-08-25T17:00:01.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-done"}}
    """.write(to: desktopTranscript, atomically: true, encoding: .utf8)
    try """
    {"type":"session_meta","payload":{"id":"subagent-session","cwd":"/tmp/subagent","originator":"Codex Desktop","source":{"subagent":{} }}}
    {"timestamp":"2026-08-25T17:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-subagent"}}
    """.write(to: subagentTranscript, atomically: true, encoding: .utf8)

    let watcher = CodexDesktopSessionWatcher(sessionsRoot: root)

    #expect(await watcher.poll(terminal: TerminalHost(kind: .unknown)).isEmpty)
}

@MainActor
@Test func codexDesktopWatcherCompletesAPartiallyWrittenLine() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("rollout-partial.jsonl")
    let metadata = #"{"type":"session_meta","payload":{"id":"partial-session","cwd":"/tmp/project","originator":"Codex Desktop","thread_source":"user"}}"#
    let partial = #"{"timestamp":"2026-08-25T17:00:00.000Z","type":"event_msg","payload":{"type":"task_sta"#
    try "\(metadata)\n\(partial)".write(to: transcript, atomically: true, encoding: .utf8)
    let watcher = CodexDesktopSessionWatcher(sessionsRoot: root)
    let terminal = TerminalHost(kind: .unknown)

    #expect(await watcher.poll(terminal: terminal).isEmpty)

    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"rted","turn_id":"turn-partial"}}"#.appending("\n").utf8))
    try handle.close()

    let events = await watcher.poll(
        now: Date().addingTimeInterval(1),
        changedURLs: [transcript],
        terminal: terminal
    )
    #expect(events.count == 1)
    #expect(events.first?.turnId == "turn-partial")
    #expect(events.first?.status == .running)
}

@MainActor
@Test func menuBarHidesDisconnectedSessions() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory)
    store.apply(.init(
        eventType: .sessionEnd,
        sessionId: "disconnected",
        cwd: "/tmp/disconnected",
        status: .stale,
        terminal: .init(kind: .unknown)
    ))
    store.apply(.init(
        eventType: .userPromptSubmit,
        sessionId: "active",
        cwd: "/tmp/active",
        status: .running,
        terminal: .init(kind: .unknown)
    ))

    #expect(store.sessions.count == 2)
    #expect(store.visibleSessions.map(\.id) == ["codex:active"])
}

@MainActor
@Test func aNewTurnClearsCompletion() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory)
    store.apply(.init(eventType: .agentTurnComplete, sessionId: "s", turnId: "one", cwd: "/tmp/repo", status: .ready, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .userPromptSubmit, occurredAt: Date().addingTimeInterval(1), sessionId: "s", turnId: "two", cwd: "/tmp/repo", status: .running, terminal: .init(kind: .unknown)))
    #expect(store.sessions.first?.completedAt == nil)
}

@MainActor
@Test func completionEmitsOneStatusItemSignal() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory)
    var completions = 0
    store.onCompletion = { completions += 1 }
    let now = Date()

    store.apply(.init(eventType: .userPromptSubmit, occurredAt: now, sessionId: "s", turnId: "one", cwd: "/tmp/repo", status: .running, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .agentTurnComplete, occurredAt: now.addingTimeInterval(1), sessionId: "s", turnId: "one", cwd: "/tmp/repo", status: .ready, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .stop, occurredAt: now.addingTimeInterval(2), sessionId: "s", turnId: "one", cwd: "/tmp/repo", status: .ready, terminal: .init(kind: .unknown)))

    #expect(completions == 1)
    #expect(store.sessions.first?.updatedAt == now.addingTimeInterval(1))
}

@MainActor
@Test func codexStopHidesInterruptedSessionWithoutCompleting() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory)
    var completions = 0
    store.onCompletion = { completions += 1 }
    let now = Date()

    store.apply(.init(provider: .codex, eventType: .userPromptSubmit, occurredAt: now, sessionId: "s", turnId: "one", cwd: "/tmp/repo", status: .running, terminal: .init(kind: .unknown)))
    store.apply(.init(provider: .codex, eventType: .stop, occurredAt: now.addingTimeInterval(1), sessionId: "s", turnId: "one", cwd: "/tmp/repo", status: .stale, terminal: .init(kind: .unknown)))

    #expect(store.sessions.first?.status == .stale)
    #expect(store.sessions.first?.completedAt == nil)
    #expect(store.visibleSessions.isEmpty)
    #expect(completions == 0)
    #expect(!SessionStore.shouldSpeakCompletion(
        for: .init(provider: .codex, eventType: .stop, sessionId: "s", cwd: "/tmp/repo", status: .ready, terminal: .init(kind: .unknown)),
        previousStatus: .running
    ))
}

@MainActor
@Test func deadAgentProcessBecomesInactive() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory)
    store.apply(.init(
        eventType: .userPromptSubmit,
        sessionId: "dead-process",
        cwd: "/tmp/repo",
        status: .running,
        terminal: .init(kind: .terminalApp, agentPid: .max)
    ))

    store.reconcileProcesses()

    #expect(store.sessions.first?.status == .stale)
    #expect(store.visibleSessions.isEmpty)
}

@MainActor
@Test func completedSessionSurvivesItsWorkerProcessExit() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "showReadyInOverlay")
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory, defaults: defaults)
    let now = Date()
    let terminal = TerminalHost(kind: .terminalApp, agentPid: .max)
    store.apply(.init(eventType: .userPromptSubmit, occurredAt: now, sessionId: "completed", turnId: "turn-1", cwd: "/tmp/repo", status: .running, terminal: terminal))
    store.apply(.init(eventType: .agentTurnComplete, occurredAt: now.addingTimeInterval(1), sessionId: "completed", turnId: "turn-1", cwd: "/tmp/repo", status: .ready, terminal: terminal))

    store.reconcileProcesses()

    #expect(store.sessions.first?.status == .ready)
    #expect(store.overlaySessions(at: now.addingTimeInterval(2)).count == 1)
}

@MainActor
@Test func suspendedAgentProcessBecomesInactive() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    defer {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
    kill(process.processIdentifier, SIGSTOP)
    for _ in 0..<50 where !SessionStore.agentProcessIsInactive(process.processIdentifier) {
        usleep(10_000)
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory)
    store.apply(.init(
        eventType: .userPromptSubmit,
        sessionId: "suspended-process",
        cwd: "/tmp/repo",
        status: .running,
        terminal: .init(kind: .terminalApp, agentPid: process.processIdentifier)
    ))
    store.reconcileProcesses()

    #expect(store.sessions.first?.status == .stale)
    #expect(store.visibleSessions.isEmpty)
}

@MainActor
@Test func interruptedCodexTranscriptBecomesInactive() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let transcript = directory.appendingPathComponent("rollout.jsonl")
    try #"{"timestamp":"2026-08-25T16:44:38Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-1","reason":"interrupted"}}"#
        .write(to: transcript, atomically: true, encoding: .utf8)
    let store = SessionStore(baseDirectory: directory)
    store.apply(.init(
        eventType: .userPromptSubmit,
        sessionId: "interrupted",
        turnId: "turn-1",
        cwd: "/tmp/repo",
        transcriptPath: transcript.path,
        status: .running,
        terminal: .init(kind: .terminalApp)
    ))

    store.reconcileProcesses()

    #expect(store.sessions.first?.status == .stale)
    #expect(store.visibleSessions.isEmpty)
}

@MainActor
@Test func lateToolEventCannotReactivateInactiveSession() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory)
    let now = Date()
    store.apply(.init(eventType: .userPromptSubmit, occurredAt: now, sessionId: "s", turnId: "root-turn", cwd: "/tmp/repo", status: .running, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .stop, occurredAt: now.addingTimeInterval(1), sessionId: "s", turnId: "root-turn", cwd: "/tmp/repo", status: .stale, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .postToolUse, occurredAt: now.addingTimeInterval(2), sessionId: "s", turnId: "subagent-turn", cwd: "/tmp/repo", status: .running, terminal: .init(kind: .unknown)))

    #expect(store.sessions.first?.status == .stale)
    #expect(store.sessions.first?.currentTurnId == "root-turn")
}

@MainActor
@Test func overlayRetainsOnlyReadySessionsForConfiguredTime() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "showReadyInOverlay")
    defaults.set(5, forKey: "overlayRetentionMinutes")
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory, defaults: defaults)
    let now = Date()
    store.apply(.init(eventType: .agentTurnComplete, occurredAt: now, sessionId: "ready", cwd: "/tmp/ready", status: .ready, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .permissionRequested, occurredAt: now, sessionId: "attention", cwd: "/tmp/attention", status: .attention, terminal: .init(kind: .unknown)))

    #expect(store.overlaySessions(at: now.addingTimeInterval(299)).count == 1)
    #expect(store.overlaySessions(at: now.addingTimeInterval(301)).isEmpty)
}

@MainActor
@Test func runningSessionNeverExpiresFromOverlay() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(1, forKey: "overlayRetentionMinutes")
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory, defaults: defaults)
    let now = Date()
    store.apply(.init(eventType: .userPromptSubmit, occurredAt: now, sessionId: "running", cwd: "/tmp/running", status: .running, terminal: .init(kind: .unknown)))

    #expect(store.overlaySessions(at: now.addingTimeInterval(3_600)).count == 1)
}

@MainActor
@Test func dismissRemovesCompletedSessionImmediately() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "showReadyInOverlay")
    defaults.set(15, forKey: "overlayRetentionMinutes")
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory, defaults: defaults)
    store.apply(.init(eventType: .agentTurnComplete, sessionId: "done", cwd: "/tmp/done", status: .ready, terminal: .init(kind: .unknown)))

    #expect(store.overlaySessions.count == 1)
    store.dismiss("codex:done")
    #expect(store.overlaySessions.isEmpty)
}

@MainActor
@Test func attentionSessionsAreDiscarded() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(15, forKey: "overlayRetentionMinutes")
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory, defaults: defaults)
    store.apply(.init(
        eventType: .permissionRequested,
        sessionId: "attention",
        cwd: "/tmp/attention",
        status: .attention,
        terminal: .init(kind: .unknown)
    ))

    #expect(store.sessions.isEmpty)
    #expect(store.overlaySessions.isEmpty)
}

@MainActor
@Test func dismissMultipleSessionsAtOnce() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "showReadyInOverlay")
    defaults.set(15, forKey: "overlayRetentionMinutes")
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory, defaults: defaults)
    store.apply(.init(eventType: .agentTurnComplete, sessionId: "done-1", cwd: "/tmp/one", status: .ready, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .agentTurnComplete, sessionId: "done-2", cwd: "/tmp/two", status: .ready, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .userPromptSubmit, sessionId: "running", cwd: "/tmp/three", status: .running, terminal: .init(kind: .unknown)))

    store.dismiss(["codex:done-1", "codex:done-2"])

    #expect(store.overlaySessions.map(\.id) == ["codex:running"])
}

@MainActor
@Test func lateCompletionDoesNotRestoreDismissedSession() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "showReadyInOverlay")
    defaults.set(15, forKey: "overlayRetentionMinutes")
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory, defaults: defaults)
    let now = Date()
    store.apply(.init(eventType: .agentTurnComplete, occurredAt: now, sessionId: "done", turnId: "turn-1", cwd: "/tmp/done", status: .ready, terminal: .init(kind: .unknown)))
    store.dismiss("codex:done", at: now.addingTimeInterval(1))

    store.apply(.init(eventType: .agentTurnComplete, occurredAt: now.addingTimeInterval(120), sessionId: "done", turnId: "turn-1", cwd: "/tmp/done", status: .ready, terminal: .init(kind: .unknown)))

    #expect(store.overlaySessions(at: now.addingTimeInterval(121)).isEmpty)
    #expect(store.visibleSessions.isEmpty)
}

@MainActor
@Test func newPromptRestoresDismissedSession() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "showReadyInOverlay")
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let now = Date()
    let store = SessionStore(baseDirectory: directory, defaults: defaults)
    store.apply(.init(eventType: .agentTurnComplete, occurredAt: now, sessionId: "session", turnId: "turn-1", cwd: "/tmp/repo", status: .ready, terminal: .init(kind: .unknown)))
    store.dismiss("codex:session", at: now.addingTimeInterval(1))

    store.apply(.init(eventType: .userPromptSubmit, occurredAt: now.addingTimeInterval(2), sessionId: "session", turnId: "turn-2", cwd: "/tmp/repo", status: .running, terminal: .init(kind: .unknown)))

    #expect(store.overlaySessions(at: now.addingTimeInterval(3)).count == 1)
    #expect(store.sessions.first?.dismissedAt == nil)
}

@MainActor
@Test func dismissalSurvivesStoreReload() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "showReadyInOverlay")
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let now = Date()
    let initialStore = SessionStore(baseDirectory: directory, defaults: defaults)
    initialStore.apply(.init(eventType: .agentTurnComplete, occurredAt: now, sessionId: "done", cwd: "/tmp/done", status: .ready, terminal: .init(kind: .unknown)))
    initialStore.dismiss("codex:done", at: now)

    let reloadedStore = SessionStore(baseDirectory: directory, defaults: defaults)

    #expect(reloadedStore.overlaySessions(at: now.addingTimeInterval(1)).isEmpty)
    #expect(reloadedStore.sessions.first?.dismissedAt != nil)
}

@MainActor
@Test func codexAndClaudeSessionsWithSameIDRemainDistinct() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory)
    store.apply(.init(provider: .codex, eventType: .userPromptSubmit, sessionId: "same", cwd: "/tmp/codex", status: .running, terminal: .init(kind: .terminalApp)))
    store.apply(.init(provider: .claude, eventType: .userPromptSubmit, sessionId: "same", cwd: "/tmp/claude", status: .running, terminal: .init(kind: .intellij)))

    #expect(Set(store.sessions.map(\.id)) == ["codex:same", "claude:same"])
    #expect(Set(store.sessions.map(\.provider)) == [.codex, .claude])
}
