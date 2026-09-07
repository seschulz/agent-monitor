import AppKit
import Foundation
import Testing
import AgentMonitorShared
@testable import AgentMonitorApp

@Test @MainActor func automaticTerminalMarkerFitsIntelliJTitleLimit() {
    let marker = JetBrainsTerminalFocus.makeTitleMarker()
    #expect(marker.count <= 30)
    #expect(marker.count >= 20)
    #expect(marker != JetBrainsTerminalFocus.makeTitleMarker())
    #expect(marker.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) })
}

@Test @MainActor func intellijProjectMatchingRespectsPathBoundaries() {
    #expect(JetBrainsTerminalFocus.containsWorkingDirectory(windowKey: "/work/project", cwd: "/work/project/src"))
    #expect(JetBrainsTerminalFocus.containsWorkingDirectory(windowKey: "/work/project", cwd: "/work/project"))
    #expect(!JetBrainsTerminalFocus.containsWorkingDirectory(windowKey: "/work/project", cwd: "/work/project-other"))
    #expect(!JetBrainsTerminalFocus.containsWorkingDirectory(windowKey: "project", cwd: "/work/project"))
}

@Test func intellijTabLinkMatchesProjectAndNameInsteadOfTabOrder() {
    let tabs: [JetBrainsTabIdentity] = [
        .init(windowKey: "~/other", tabName: "Agent"),
        .init(windowKey: "~/project", tabName: "Build"),
        .init(windowKey: "~/project", tabName: "Agent")
    ]
    #expect(JetBrainsTabLink.uniqueMatch(windowKey: "~/project", tabName: "Agent", in: tabs) == 2)
    #expect(JetBrainsTabLink.uniqueMatch(windowKey: "~/project", tabName: "Agent", in: tabs.reversed()) == 0)
    #expect(JetBrainsTabLink.uniqueMatch(windowKey: "~/project", tabName: "agent", in: tabs) == nil)
    #expect(JetBrainsTabLink.uniqueMatch(windowKey: "~/missing", tabName: "Agent", in: tabs) == nil)
}

@Test func intellijTabLinkRejectsAmbiguousOrRenamedTabs() {
    let duplicates = [JetBrainsTabIdentity(windowKey: "project", tabName: "Local"),
                      JetBrainsTabIdentity(windowKey: "project", tabName: "Local")]
    #expect(JetBrainsTabLink.uniqueMatch(windowKey: "project", tabName: "Local", in: duplicates) == nil)
    #expect(JetBrainsTabLink.uniqueMatch(windowKey: "project", tabName: "Old name", in: duplicates) == nil)
}

@Test func intellijTabLinkDoesNotSurviveIDEProcessReuse() throws {
    let startedAt = Date(timeIntervalSince1970: 1000)
    let link = JetBrainsTabLink(windowKey: "project", tabName: "Agent", hostPID: 42,
                               hostStartedAt: startedAt, savedAt: startedAt)
    #expect(link.belongsTo(pid: 42, startedAt: startedAt.addingTimeInterval(0.5)))
    #expect(!link.belongsTo(pid: 43, startedAt: startedAt))
    #expect(!link.belongsTo(pid: 42, startedAt: startedAt.addingTimeInterval(10)))
    let restored = try JSONDecoder().decode(JetBrainsTabLink.self, from: JSONEncoder().encode(link))
    #expect(restored == link)
}

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
    #expect(HookConfigurationService.hasManagedInstallation(paths: paths))
    #expect(try String(contentsOf: paths.codexHooks).contains("existing-hook"))
    #expect(try String(contentsOf: paths.codexHooks).contains(helper.path))
    #expect(try String(contentsOf: paths.claudeSettings).contains(helper.path))
    let dispatcher = codex.appendingPathComponent("bin/agent-monitor-notify")
    #expect(try String(contentsOf: dispatcher, encoding: .utf8).contains("existing-notify"))

    try HookConfigurationService.remove(paths: paths)

    #expect(!(try String(contentsOf: paths.codexHooks).contains("agent-monitor-helper")))
    #expect(!(try String(contentsOf: paths.claudeSettings).contains("agent-monitor-helper")))
    #expect(try String(contentsOf: paths.codexConfig).contains(#"notify = ["existing-notify","--quiet"]"#))
    #expect(!HookConfigurationService.hasManagedInstallation(paths: paths))
}

@Test func stableHelperInstallerReplacesTheHelperAndKeepsItExecutable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("bundled-helper")
    let destination = root.appendingPathComponent("Application Support/bin/agent-monitor-helper")
    try Data("first".utf8).write(to: source)

    try StableHelperInstaller.install(from: source, to: destination)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "first")

    try Data("second".utf8).write(to: source)
    try StableHelperInstaller.install(from: source, to: destination)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "second")
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    let permissions = attributes[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o755)
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

@MainActor
@Test func overlayPositionKeepsItsScreenEdgeInsetsAfterResolutionChange() {
    let windowSize = NSSize(width: 320, height: 160)
    let originalScreen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    let originalTopLeft = NSPoint(x: 1_100, y: 880)
    let anchor = OverlayController.positionAnchor(
        for: originalTopLeft,
        windowSize: windowSize,
        visibleFrame: originalScreen,
        screenID: 42
    )

    let resizedScreen = NSRect(x: -200, y: 40, width: 2_560, height: 1_440)
    let restored = OverlayController.topLeft(
        for: anchor,
        windowSize: windowSize,
        visibleFrame: resizedScreen
    )

    #expect(anchor.horizontalEdge == .right)
    #expect(anchor.verticalEdge == .top)
    #expect(anchor.horizontalInset == 20)
    #expect(anchor.verticalInset == 20)
    #expect(restored == NSPoint(x: 2_020, y: 1_460))
}

@Test func compactOverlayTimeFormatting() {
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

    #expect(SessionRow.compactTime(for: session, at: start.addingTimeInterval(42)) == "42s")
    #expect(SessionRow.compactTime(for: session, at: start.addingTimeInterval(125)) == "2m")
    #expect(SessionRow.compactTime(for: session, at: start.addingTimeInterval(7_200)) == "2h")

    let running = SessionRecord(event: .init(
        eventType: .userPromptSubmit,
        occurredAt: start,
        sessionId: "running",
        cwd: "/tmp/repo",
        status: .running,
        terminal: .init(kind: .unknown)
    ))
    #expect(SessionRow.compactTime(for: running, at: start.addingTimeInterval(42)) == "42s")
    #expect(SessionRow.compactTime(for: running, at: start.addingTimeInterval(754)) == "12m")
    #expect(SessionRow.compactTime(for: running, at: start.addingTimeInterval(58_119)) == "16h")
}

@Test func overlayDensityOffersThreeIncreasingSizes() {
    #expect(OverlayDensity.allCases == [.compact, .standard, .spacious])
    #expect(OverlayDensity.compact.width < OverlayDensity.standard.width)
    #expect(OverlayDensity.standard.width < OverlayDensity.spacious.width)
    #expect(OverlayDensity.compact.rowPadding < OverlayDensity.standard.rowPadding)
    #expect(OverlayDensity.standard.rowPadding == OverlayDensity.spacious.rowPadding)
}

@Test func legacyMinimalOverlayDensityMigratesToCompact() {
    let suiteName = "OverlayDensityMigrationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set("minimal", forKey: "overlayDensity")
    OverlayDensity.migrateLegacyPreference(in: defaults)
    OverlayDensity.migrateLegacyPreference(in: defaults)

    #expect(defaults.string(forKey: "overlayDensity") == OverlayDensity.compact.rawValue)
    #expect(defaults.integer(forKey: "overlayDensityNamingVersion") == 1)
}

@Test func overlayAppearanceChoosesReadableTextColorScheme() {
    #expect(OverlayAppearanceStyle.automatic.resolvedColorScheme(
        customColorHex: "#000000",
        systemColorScheme: .light
    ) == .light)
    #expect(OverlayAppearanceStyle.dark.resolvedColorScheme(
        customColorHex: "#FFFFFF",
        systemColorScheme: .light
    ) == .dark)
    #expect(OverlayAppearanceStyle.light.resolvedColorScheme(
        customColorHex: "#000000",
        systemColorScheme: .dark
    ) == .light)
    #expect(OverlayAppearanceStyle.custom.resolvedColorScheme(
        customColorHex: "#10141C",
        systemColorScheme: .light
    ) == .dark)
    #expect(OverlayAppearanceStyle.custom.resolvedColorScheme(
        customColorHex: "#F4F6FA",
        systemColorScheme: .dark
    ) == .light)
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
    let phrase = SpeechMessageTemplate.render(
        "{agent} finished {project} in {terminal} at {directory}",
        agent: "Claude",
        project: "agent-monitor",
        terminal: "Ghostty",
        directory: "/tmp/agent-monitor"
    )

    #expect(phrase == "Claude finished agent-monitor in Ghostty at /tmp/agent-monitor")
}

@Test func blankSpeechMessageTemplateUsesDefaultMessage() {
    let phrase = SpeechMessageTemplate.render(
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, diagnosticsEnabled: true, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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

    SessionStore(completionAlertDelay: .zero, baseDirectory: directory, diagnosticsEnabled: true, speechOutput: { _, _ in }).apply(event)
    let reloaded = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, diagnosticsEnabled: true, speechOutput: { _, _ in })
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, diagnosticsEnabled: true, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, defaults: defaults, diagnosticsEnabled: true, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, diagnosticsEnabled: false, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    #expect(interruption.map(\.eventType) == [.userPromptSubmit, .interrupt])
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
    store.apply(.init(eventType: .agentTurnComplete, sessionId: "s", turnId: "one", cwd: "/tmp/repo", status: .ready, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .userPromptSubmit, occurredAt: Date().addingTimeInterval(1), sessionId: "s", turnId: "two", cwd: "/tmp/repo", status: .running, terminal: .init(kind: .unknown)))
    #expect(store.sessions.first?.completedAt == nil)
}

@MainActor
@Test func repeatedSessionStartDoesNotCompleteAnActiveCodexTurn() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
    var completions = 0
    store.onCompletion = { completions += 1 }
    let now = Date()

    store.apply(.init(
        eventType: .userPromptSubmit,
        occurredAt: now,
        sessionId: "session",
        turnId: "turn",
        cwd: "/tmp/repo",
        status: .running,
        terminal: .init(kind: .unknown)
    ))
    store.apply(.init(
        eventType: .sessionStart,
        occurredAt: now.addingTimeInterval(1),
        sessionId: "session",
        cwd: "/tmp/repo",
        status: .ready,
        terminal: .init(kind: .unknown)
    ))

    #expect(store.sessions.first?.status == .running)
    #expect(store.sessions.first?.completedAt == nil)

    store.apply(.init(
        eventType: .agentTurnComplete,
        occurredAt: now.addingTimeInterval(2),
        sessionId: "session",
        turnId: "turn",
        cwd: "/tmp/repo",
        status: .ready,
        terminal: .init(kind: .unknown)
    ))

    #expect(store.sessions.first?.status == .ready)
    #expect(store.sessions.first?.completedAt == now.addingTimeInterval(2))
    #expect(completions == 1)
}

@MainActor
@Test func completionEmitsOneStatusItemSignal() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, defaults: defaults, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, defaults: defaults, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
    let now = Date()
    store.apply(.init(eventType: .agentTurnComplete, occurredAt: now, sessionId: "ready", cwd: "/tmp/ready", status: .ready, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .permissionRequested, occurredAt: now, sessionId: "attention", cwd: "/tmp/attention", status: .attention, terminal: .init(kind: .unknown)))

    #expect(store.overlaySessions(at: now.addingTimeInterval(299)).count == 2)
    #expect(store.overlaySessions(at: now.addingTimeInterval(301)).map(\.id) == ["codex:attention"])
}

@MainActor
@Test func runningSessionNeverExpiresFromOverlay() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(1, forKey: "overlayRetentionMinutes")
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, defaults: defaults, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, defaults: defaults, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
    store.apply(.init(eventType: .agentTurnComplete, sessionId: "done", cwd: "/tmp/done", status: .ready, terminal: .init(kind: .unknown)))

    #expect(store.overlaySessions.count == 1)
    store.dismiss("codex:done")
    #expect(store.overlaySessions.isEmpty)
}

@MainActor
@Test func dismissHidesRunningSessionUntilTheNextPrompt() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, defaults: defaults, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
    let now = Date()
    store.apply(.init(
        eventType: .userPromptSubmit,
        occurredAt: now,
        sessionId: "running",
        turnId: "turn-1",
        cwd: "/tmp/running",
        status: .running,
        terminal: .init(kind: .unknown)
    ))

    store.dismiss("codex:running", at: now.addingTimeInterval(1))
    store.apply(.init(
        eventType: .postToolUse,
        occurredAt: now.addingTimeInterval(2),
        sessionId: "running",
        turnId: "turn-1",
        cwd: "/tmp/running",
        status: .running,
        terminal: .init(kind: .unknown)
    ))
    #expect(store.overlaySessions(at: now.addingTimeInterval(3)).isEmpty)

    store.apply(.init(
        eventType: .userPromptSubmit,
        occurredAt: now.addingTimeInterval(4),
        sessionId: "running",
        turnId: "turn-2",
        cwd: "/tmp/running",
        status: .running,
        terminal: .init(kind: .unknown)
    ))
    #expect(store.overlaySessions(at: now.addingTimeInterval(5)).map(\.id) == ["codex:running"])
}

@MainActor
@Test func attentionSessionsStayVisibleWithoutExpiring() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(15, forKey: "overlayRetentionMinutes")
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, defaults: defaults, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
    store.apply(.init(
        eventType: .permissionRequested,
        sessionId: "attention",
        cwd: "/tmp/attention",
        status: .attention,
        terminal: .init(kind: .unknown)
    ))

    #expect(store.sessions.first?.status == .attention)
    #expect(store.overlaySessions.count == 1)
    #expect(store.overlaySessions(at: Date().addingTimeInterval(3600)).count == 1)
}

@MainActor
@Test func dismissMultipleSessionsAtOnce() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "showReadyInOverlay")
    defaults.set(15, forKey: "overlayRetentionMinutes")
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, defaults: defaults, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, defaults: defaults, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, defaults: defaults, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
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
    let initialStore = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, defaults: defaults, speechOutput: { _, _ in })
    initialStore.apply(.init(eventType: .agentTurnComplete, occurredAt: now, sessionId: "done", cwd: "/tmp/done", status: .ready, terminal: .init(kind: .unknown)))
    initialStore.dismiss("codex:done", at: now)

    let reloadedStore = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, defaults: defaults, speechOutput: { _, _ in })

    #expect(reloadedStore.overlaySessions(at: now.addingTimeInterval(1)).isEmpty)
    #expect(reloadedStore.sessions.first?.dismissedAt != nil)
}

@MainActor
@Test func codexAndClaudeSessionsWithSameIDRemainDistinct() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: directory, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
    store.apply(.init(provider: .codex, eventType: .userPromptSubmit, sessionId: "same", cwd: "/tmp/codex", status: .running, terminal: .init(kind: .terminalApp)))
    store.apply(.init(provider: .claude, eventType: .userPromptSubmit, sessionId: "same", cwd: "/tmp/claude", status: .running, terminal: .init(kind: .intellij)))

    #expect(Set(store.sessions.map(\.id)) == ["codex:same", "claude:same"])
    #expect(Set(store.sessions.map(\.provider)) == [.codex, .claude])
}

@MainActor
@Test func attentionLifecycleAlertsOnceAndResumesForBothProviders() throws {
    for provider in AgentProvider.allCases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "AgentMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "showReadyInOverlay")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(completionAlertDelay: .zero, baseDirectory: root, defaults: defaults, speechOutput: { _, _ in })
        store.setPermissionAlertsEnabled(true, for: .codex)
        var alerts = 0
        store.onAttention = { alerts += 1 }
        let now = Date()
        func event(_ type: MonitorEventType, _ status: SessionStatus, seconds: Double, tool: String? = nil) -> MonitorEvent {
            .init(provider: provider, eventType: type, occurredAt: now.addingTimeInterval(seconds), sessionId: "s", turnId: "t", cwd: "/tmp/test", status: status, terminal: .init(kind: .unknown), toolUseID: tool, attentionReason: status == .attention ? "Waiting for input" : nil)
        }
        store.apply(event(.userPromptSubmit, .running, seconds: 0))
        store.apply(event(.inputRequested, .attention, seconds: 1, tool: "question"))
        store.apply(event(.inputRequested, .attention, seconds: 2))
        #expect(alerts == 1)
        #expect(store.overlaySessions.count == 1)
        #expect(store.overlaySessions(at: now.addingTimeInterval(3600)).count == 1)
        #expect(store.sessions.first?.attentionToolUseID == "question")
        store.apply(.init(provider: provider, eventType: .permissionRequested, occurredAt: now.addingTimeInterval(2), sessionId: "s", turnId: "t", cwd: "/tmp/test", status: .attention, terminal: .init(kind: .unknown), attentionReason: "Waiting for permission"))
        #expect(store.sessions.first?.attentionReason == "Waiting for input")
        #expect(alerts == 1)
        store.apply(event(.postToolUse, .running, seconds: 3, tool: "parallel"))
        #expect(store.sessions.first?.status == .attention)
        store.apply(event(.sessionStart, .ready, seconds: 4))
        #expect(store.sessions.first?.status == .attention)
        #expect(store.sessions.first?.attentionReason == "Waiting for input")
        store.apply(event(.postToolUse, .running, seconds: 5, tool: "question"))
        #expect(store.sessions.first?.status == .running)
        #expect(store.sessions.first?.attentionReason == nil)
        #expect(store.sessions.first?.attentionToolUseID == nil)
        store.apply(event(.permissionRequested, .attention, seconds: 6, tool: "approval"))
        #expect(alerts == 2)
        let restored = SessionStore(completionAlertDelay: .zero, baseDirectory: root, defaults: defaults, speechOutput: { _, _ in })
        #expect(restored.visibleSessions.first?.status == .attention)
        #expect(restored.visibleSessions.first?.attentionToolUseID == "approval")
        store.apply(event(.sessionEnd, .closed, seconds: 7))
        #expect(store.visibleSessions.isEmpty)
    }
}

@MainActor
@Test func attentionRequestsDoNotResurrectFinishedOrOlderTurns() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: root, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
    var alerts = 0
    var completions = 0
    store.onAttention = { alerts += 1 }
    store.onCompletion = { completions += 1 }
    let now = Date()
    store.apply(.init(eventType: .userPromptSubmit, occurredAt: now, sessionId: "s", turnId: "new", cwd: "/tmp/test", status: .running, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .permissionRequested, occurredAt: now.addingTimeInterval(1), sessionId: "s", turnId: "old", cwd: "/tmp/test", status: .attention, terminal: .init(kind: .unknown)))
    #expect(store.sessions.first?.status == .running)
    #expect(alerts == 0)
    store.apply(.init(eventType: .permissionRequested, occurredAt: now.addingTimeInterval(2), sessionId: "s", turnId: "new", cwd: "/tmp/test", status: .attention, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .agentTurnComplete, occurredAt: now.addingTimeInterval(3), sessionId: "s", turnId: "new", cwd: "/tmp/test", status: .ready, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .permissionRequested, occurredAt: now.addingTimeInterval(4), sessionId: "s", turnId: "new", cwd: "/tmp/test", status: .attention, terminal: .init(kind: .unknown)))
    #expect(store.sessions.first?.status == .ready)
    #expect(alerts == 1)
    #expect(completions == 1)
}

@MainActor
@Test func attentionSortsFirstAndDeadWaitingAgentsDisappear() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: root, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
    store.apply(.init(eventType: .userPromptSubmit, sessionId: "running", cwd: "/tmp/test", status: .running, terminal: .init(kind: .unknown)))
    store.apply(.init(eventType: .permissionRequested, sessionId: "waiting", cwd: "/tmp/test", status: .attention, terminal: .init(kind: .unknown, agentPid: .max)))
    #expect(store.visibleSessions.first?.id == "codex:waiting")
    store.reconcileProcesses()
    #expect(store.visibleSessions.map(\.id) == ["codex:running"])
}

@MainActor
@Test func lateClaudePermissionReminderDoesNotReactivateCompletedSession() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(completionAlertDelay: .zero, baseDirectory: root, speechOutput: { _, _ in })
    store.setPermissionAlertsEnabled(true, for: .codex)
    let now = Date()
    store.apply(.init(provider: .claude, eventType: .userPromptSubmit, occurredAt: now, sessionId: "s", cwd: "/tmp/test", status: .running, terminal: .init(kind: .unknown)))
    store.apply(.init(provider: .claude, eventType: .stop, occurredAt: now.addingTimeInterval(1), sessionId: "s", cwd: "/tmp/test", status: .ready, terminal: .init(kind: .unknown)))
    store.apply(.init(provider: .claude, eventType: .permissionRequested, occurredAt: now.addingTimeInterval(2), sessionId: "s", cwd: "/tmp/test", status: .attention, terminal: .init(kind: .unknown), attentionReason: "Waiting for permission"))
    #expect(store.sessions.first?.status == .ready)
    #expect(store.sessions.first?.attentionReason == nil)
}

@MainActor
@Test func questionAudioWinsOverFinishInEitherArrivalOrder() async throws {
    for provider in AgentProvider.allCases {
        for finishFirst in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let suite = "AgentMonitorTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer {
                try? FileManager.default.removeItem(at: root)
                defaults.removePersistentDomain(forName: suite)
            }
            defaults.set(true, forKey: "speechEnabled")
            defaults.set(true, forKey: "speakOnCompletion")
            defaults.set("Test Voice", forKey: "speechVoice")
            var spoken: [String] = []
            var completions = 0
            let store = SessionStore(completionAlertDelay: .milliseconds(40), baseDirectory: root,
                                     defaults: defaults, diagnosticsEnabled: true,
                                     speechOutput: { phrase, voice in
                spoken.append(phrase)
                #expect(voice == "Test Voice")
            })
            store.onCompletion = { completions += 1 }
            func event(_ type: MonitorEventType, _ status: SessionStatus, tool: String? = nil) -> MonitorEvent {
                .init(provider: provider, eventType: type, sessionId: "s", turnId: "t", cwd: "/tmp/test",
                      status: status, terminal: .init(kind: .unknown), toolUseID: tool,
                      attentionReason: status == .attention ? "Waiting for input" : nil)
            }
            let completion: MonitorEventType = provider == .codex ? .agentTurnComplete : .stop
            store.apply(event(.userPromptSubmit, .running))
            if finishFirst { store.apply(event(completion, .ready)) }
            store.apply(event(.inputRequested, .attention, tool: "question"))
            if !finishFirst { store.apply(event(completion, .ready)) }
            store.apply(event(.inputRequested, .attention, tool: "question"))
            if provider == .codex { store.apply(event(.stop, .stale)) }
            store.apply(event(.postToolUse, .running, tool: "unrelated-tool"))
            try await Task.sleep(for: .milliseconds(100))
            #expect(store.sessions.first?.status == .attention)
            #expect(store.sessions.first?.completedAt == nil)
            #expect(completions == 0)
            #expect(spoken == ["\(provider.displayName) needs your input"])
            #expect(store.diagnosticEvents.filter(\.speechTriggered).count == 1)
            // Answering does not replay the premature finish. A new finish is required.
            store.apply(event(.postToolUse, .running, tool: "question"))
            try await Task.sleep(for: .milliseconds(100))
            #expect(store.sessions.first?.status == .running)
            #expect(completions == 0)
            let finished = event(completion, .ready)
            store.apply(finished)
            store.apply(finished)
            try await Task.sleep(for: .milliseconds(100))
            #expect(store.sessions.first?.status == .ready)
            #expect(completions == 1)
            #expect(spoken == ["\(provider.displayName) needs your input", "\(provider.displayName) finished"])
            #expect(store.diagnosticEvents.filter(\.speechTriggered).count == 2)
        }
    }
}

@MainActor
@Test func attentionSpeechRespectsMasterAndSeparatePreference() {
    for provider in AgentProvider.allCases {
        for enabled in [false, true] {
            for attentionEnabled in [false, true] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let suite = "AgentMonitorTests.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
                defaults.set(enabled, forKey: "speechEnabled")
                defaults.set(attentionEnabled, forKey: "speakOnAttention")
                defaults.set(false, forKey: "speakOnCompletion")
                var spoken: [String] = []
                let store = SessionStore(baseDirectory: root, defaults: defaults, diagnosticsEnabled: true,
                                         speechOutput: { phrase, _ in spoken.append(phrase) })
                store.setPermissionAlertsEnabled(true, for: .codex)
                store.apply(.init(provider: provider, eventType: .permissionRequested, sessionId: "s",
                                  cwd: "/tmp/test", status: .attention, terminal: .init(kind: .unknown),
                                  attentionReason: "Waiting for permission"))
                #expect(store.sessions.first?.status == .attention)
                #expect(spoken == (enabled && attentionEnabled ? ["\(provider.displayName) needs your permission"] : []))
                #expect(store.diagnosticEvents.last?.speechTriggered == (enabled && attentionEnabled))
            }
        }
    }
}

@MainActor
@Test func interruptedQuestionAndCancelledCompletionRemainSilent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "speechEnabled")
    defaults.set(true, forKey: "speakOnCompletion")
    var spoken: [String] = []
    let store = SessionStore(completionAlertDelay: .milliseconds(40), baseDirectory: root, defaults: defaults,
                             speechOutput: { phrase, _ in spoken.append(phrase) })
    func event(_ type: MonitorEventType, _ status: SessionStatus) -> MonitorEvent {
        .init(eventType: type, sessionId: "s", cwd: "/tmp/test", status: status,
              terminal: .init(kind: .unknown), attentionReason: status == .attention ? "Waiting for input" : nil)
    }
    store.apply(event(.inputRequested, .attention))
    store.apply(event(.interrupt, .stale))
    #expect(store.visibleSessions.isEmpty)
    store.apply(event(.userPromptSubmit, .running))
    store.apply(event(.agentTurnComplete, .ready))
    store.apply(event(.userPromptSubmit, .running))
    try await Task.sleep(for: .milliseconds(100))
    #expect(store.sessions.first?.status == .running)
    #expect(spoken == ["Codex needs your input"])
    store.apply(event(.agentTurnComplete, .ready))
    store.dismiss("codex:s")
    try await Task.sleep(for: .milliseconds(100))
    #expect(spoken.count == 1)
}

@MainActor
@Test func providerPermissionToggleMutesWithoutMutingQuestions() {
    for provider in AgentProvider.allCases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AgentMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "speechEnabled")
        defaults.set(true, forKey: "speakOnAttention")
        defaults.set(true, forKey: "speakOnCompletion")
        defaults.set(true, forKey: "attentionNotificationsEnabled")
        var spoken: [String] = []
        var attentionSignals = 0
        let store = SessionStore(completionAlertDelay: .zero, baseDirectory: root, defaults: defaults,
                                 diagnosticsEnabled: true, speechOutput: { phrase, _ in spoken.append(phrase) })
        store.onAttention = { attentionSignals += 1 }
        func event(_ type: MonitorEventType, _ status: SessionStatus) -> MonitorEvent {
            .init(provider: provider, eventType: type, sessionId: "s", cwd: "/tmp/test", status: status,
                  terminal: .init(kind: .unknown), toolUseID: "tool",
                  attentionReason: type == .inputRequested ? "Waiting for input" : "Waiting for permission")
        }
        store.setPermissionAlertsEnabled(false, for: provider)
        store.apply(event(.userPromptSubmit, .running))
        for _ in 0..<3 { store.apply(event(.permissionRequested, .attention)) }
        #expect(store.visibleSessions.first?.status == .running)
        #expect(attentionSignals == 0)
        #expect(spoken.isEmpty)
        #expect(store.diagnosticEvents.last?.outcome == .ignoredPermissionAlertsDisabled)
        #expect(store.diagnosticEvents.last?.notificationTriggered == false)
        #expect(store.diagnosticEvents.last?.speechTriggered == false)

        defaults.set(false, forKey: "inputNotificationsEnabled")
        defaults.set(false, forKey: "permissionNotificationsEnabled")
        store.apply(event(.inputRequested, .attention))
        store.apply(event(.permissionRequested, .attention))
        #expect(store.visibleSessions.first?.attentionReason == "Waiting for input")
        #expect(attentionSignals == 1)
        #expect(spoken == ["\(provider.displayName) needs your input"])
        store.apply(event(.postToolUse, .running))
        store.apply(event(provider == .codex ? .agentTurnComplete : .stop, .ready))
        #expect(spoken.last == "\(provider.displayName) finished")

        store.setPermissionAlertsEnabled(true, for: provider)
        store.apply(event(.userPromptSubmit, .running))
        store.apply(event(.permissionRequested, .attention))
        #expect(store.visibleSessions.first?.status == .attention)
        #expect(attentionSignals == 2)
        #expect(spoken.last == "\(provider.displayName) needs your permission")
    }
}

@MainActor
@Test func disablingPermissionAlertsClearsExistingIndicatorsAndSurvivesRelaunch() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    let store = SessionStore(baseDirectory: root, defaults: defaults)
    store.setPermissionAlertsEnabled(true, for: .codex)
    for provider in AgentProvider.allCases {
        store.apply(.init(provider: provider, eventType: .permissionRequested, sessionId: "permission", cwd: "/tmp/test",
                          status: .attention, terminal: .init(kind: .unknown), toolUseID: "approval", attentionReason: "Waiting for permission"))
        store.apply(.init(provider: provider, eventType: .inputRequested, sessionId: "input", cwd: "/tmp/test",
                          status: .attention, terminal: .init(kind: .unknown), toolUseID: "question", attentionReason: "Waiting for input"))
    }
    for provider in AgentProvider.allCases { store.setPermissionAlertsEnabled(false, for: provider) }
    for session in store.sessions {
        if session.id.hasSuffix(":permission") {
            #expect(session.status == .running)
            #expect(session.attentionReason == nil)
            #expect(session.attentionToolUseID == nil)
        } else {
            #expect(session.status == .attention)
            #expect(session.attentionToolUseID == "question")
        }
    }
    #expect(store.visibleSessions.filter { $0.status == .attention }.count == 2)
    let restored = SessionStore(baseDirectory: root, defaults: defaults)
    #expect(restored.sessions.map(\.id) == store.sessions.map(\.id))
    #expect(restored.sessions.map(\.status) == store.sessions.map(\.status))
    #expect(restored.sessions.map(\.attentionReason) == store.sessions.map(\.attentionReason))
    #expect(restored.sessions.map(\.attentionToolUseID) == store.sessions.map(\.attentionToolUseID))
    #expect(defaults.bool(forKey: "codexPermissionAlertsEnabled") == false)

    // Also clear permission state saved before the preference changed, such as
    // a launch after changing the setting while the monitor was not running.
    store.setPermissionAlertsEnabled(true, for: .codex)
    store.apply(.init(eventType: .permissionRequested, sessionId: "permission", cwd: "/tmp/test", status: .attention,
                      terminal: .init(kind: .unknown), attentionReason: "Waiting for permission"))
    defaults.set(false, forKey: "codexPermissionAlertsEnabled")
    let restarted = SessionStore(baseDirectory: root, defaults: defaults)
    #expect(restarted.sessions.first { $0.id == "codex:permission" }?.status == .running)
}

@MainActor
@Test func permissionDefaultsAndSwitchesAreIndependentForEachAgent() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    let store = SessionStore(baseDirectory: root, defaults: defaults)
    #expect(!AlertPreferences.permissionEnabled(for: .codex, defaults: defaults))
    #expect(AlertPreferences.permissionEnabled(for: .claude, defaults: defaults))
    func request(_ provider: AgentProvider) -> MonitorEvent {
        .init(provider: provider, eventType: .permissionRequested, sessionId: "s", cwd: "/tmp/test", status: .attention,
              terminal: .init(kind: .unknown), attentionReason: "Waiting for permission")
    }
    for provider in AgentProvider.allCases {
        store.apply(.init(provider: provider, eventType: .userPromptSubmit, sessionId: "s", cwd: "/tmp/test", status: .running, terminal: .init(kind: .unknown)))
        store.apply(request(provider))
    }
    #expect(store.sessions.first { $0.provider == .codex }?.status == .running)
    #expect(store.sessions.first { $0.provider == .claude }?.status == .attention)
    store.setPermissionAlertsEnabled(true, for: .codex)
    store.apply(request(.codex))
    store.setPermissionAlertsEnabled(false, for: .claude)
    #expect(store.sessions.first { $0.provider == .codex }?.status == .attention)
    #expect(store.sessions.first { $0.provider == .claude }?.status == .running)
    let restored = SessionStore(baseDirectory: root, defaults: defaults)
    #expect(restored.sessions.first { $0.provider == .codex }?.status == .attention)
    #expect(restored.sessions.first { $0.provider == .claude }?.status == .running)
}

@Test func alertSettingsMigrationPreservesCustomizationsAndAppliesProviderDefaults() {
    let suite = "AgentMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: "permissionAlertsEnabled")
    defaults.set(false, forKey: "speakOnAttention")
    defaults.set(true, forKey: "attentionNotificationsEnabled")
    defaults.set("Grandpa", forKey: "speechVoice")
    defaults.set("{project} is ready", forKey: "speechCompletionTemplate")
    AlertPreferences.migrate(defaults)
    #expect(!AlertPreferences.permissionEnabled(for: .codex, defaults: defaults))
    #expect(AlertPreferences.permissionEnabled(for: .claude, defaults: defaults))
    for trigger in [AlertTrigger.input, .permission] {
        #expect(!defaults.bool(forKey: trigger.speechKey))
        #expect(defaults.bool(forKey: trigger.notificationKey))
    }
    #expect(defaults.string(forKey: "speechVoice") == "Grandpa")
    #expect(defaults.string(forKey: "speechCompletionTemplate") == "{project} is ready")
    defaults.set(true, forKey: "codexPermissionAlertsEnabled")
    defaults.set(false, forKey: "claudePermissionAlertsEnabled")
    defaults.set(true, forKey: "speakOnInput")
    defaults.set(false, forKey: "inputNotificationsEnabled")
    AlertPreferences.migrate(defaults)
    #expect(AlertPreferences.permissionEnabled(for: .codex, defaults: defaults))
    #expect(!AlertPreferences.permissionEnabled(for: .claude, defaults: defaults))
    #expect(defaults.bool(forKey: "speakOnInput"))
    #expect(!defaults.bool(forKey: "inputNotificationsEnabled"))
}

@MainActor
@Test func everyTriggerUsesItsOwnSpeechToggleTemplateAndBlankFallback() {
    for provider in AgentProvider.allCases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AgentMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "speechEnabled")
        defaults.set(true, forKey: "speakOnCompletion")
        var spoken: [String] = []
        let store = SessionStore(completionAlertDelay: .zero, baseDirectory: root, defaults: defaults,
                                 speechOutput: { phrase, _ in spoken.append(phrase) })
        store.setPermissionAlertsEnabled(true, for: provider)
        func emit(_ trigger: AlertTrigger) {
            store.apply(.init(provider: provider, eventType: .userPromptSubmit, sessionId: "s", cwd: "/tmp/project",
                              status: .running, terminal: .init(kind: .unknown)))
            let type: MonitorEventType = trigger == .finished ? (provider == .codex ? .agentTurnComplete : .stop)
                : trigger == .input ? .inputRequested : .permissionRequested
            store.apply(.init(provider: provider, eventType: type, sessionId: "s", cwd: "/tmp/project",
                              status: trigger == .finished ? .ready : .attention, terminal: .init(kind: .unknown),
                              attentionReason: trigger == .input ? "Waiting for input" : "Waiting for permission"))
        }
        for trigger in AlertTrigger.allCases {
            defaults.set("\(trigger.rawValue): {agent} / {project} / {directory}", forKey: trigger.templateKey)
            let before = spoken.count
            defaults.set(false, forKey: trigger.speechKey)
            emit(trigger)
            #expect(spoken.count == before)
            defaults.set(true, forKey: trigger.speechKey)
            emit(trigger)
            #expect(spoken.last == "\(trigger.rawValue): \(provider.displayName) / project / /tmp/project")
            defaults.set("  \n  ", forKey: trigger.templateKey)
            emit(trigger)
            #expect(spoken.last == trigger.defaultMessage.replacingOccurrences(of: "{agent}", with: provider.displayName))
        }
    }
}
