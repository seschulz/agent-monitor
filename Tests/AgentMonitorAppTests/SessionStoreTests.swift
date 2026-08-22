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

@Test func nativeIntegrationRepairsRecursiveLegacyNotifyDispatcher() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent(".codex")
    let claude = root.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: codex.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    let paths = HookConfigurationPaths(
        codexHooks: codex.appendingPathComponent("hooks.json"),
        codexConfig: codex.appendingPathComponent("config.toml"),
        claudeSettings: claude.appendingPathComponent("settings.json")
    )
    let dispatcher = codex.appendingPathComponent("bin/agent-monitor-notify")
    let previous = try String(data: JSONEncoder().encode([dispatcher.path]), encoding: .utf8)!
    let notify = ["/Applications/SkyComputerUseClient", "turn-ended", "--previous-notify", previous]
    let encoded = try String(data: JSONEncoder().encode(notify), encoding: .utf8)!
    try "# BEGIN Agent Monitor\n# END Agent Monitor\nnotify = \(encoded)\nmodel = \"test\"\n"
        .write(to: paths.codexConfig, atomically: true, encoding: .utf8)
    try "legacy".write(to: dispatcher, atomically: true, encoding: .utf8)

    try HookConfigurationService.repairInstalledCodexNotify(helperURL: root.appendingPathComponent("helper"), paths: paths)

    let repaired = try String(contentsOf: paths.codexConfig)
    #expect(repaired.contains(#"notify = ["/Applications/SkyComputerUseClient","turn-ended"]"#))
    #expect(!repaired.contains(#"\/Applications"#))
    #expect(!repaired.contains("previous-notify"))
    #expect(repaired.contains("model = \"test\""))
    #expect(!repaired.contains("Agent Monitor"))
    #expect(!FileManager.default.fileExists(atPath: dispatcher.path))
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

    try HookConfigurationService.repairInstalledCodexNotify(helperURL: helper, paths: paths)
    #expect(try String(contentsOf: paths.codexConfig, encoding: .utf8) == installed)
}

@Test func elapsedSessionTimeFormatting() {
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(SessionRow.elapsedTime(from: start, to: start.addingTimeInterval(5)) == "0:05")
    #expect(SessionRow.elapsedTime(from: start, to: start.addingTimeInterval(754)) == "12:34")
    #expect(SessionRow.elapsedTime(from: start, to: start.addingTimeInterval(3_723)) == "1:02:03")
}

@Test func minimalOverlayTimeFormatting() {
    let start = Date(timeIntervalSince1970: 1_000)
    let ready = MonitorEvent(
        eventType: .stop,
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

    #expect(SessionStore.shouldSpeakCompletion(for: stop, previousStatus: .ready))
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
    #expect(!SessionStore.shouldSpeakCompletion(for: completion, previousStatus: .ready))
}

@MainActor
@Test func ignoresDuplicatesAndOutOfOrderEvents() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SessionStore(baseDirectory: directory)
    let now = Date()
    let running = MonitorEvent(eventId: "new", eventType: .userPromptSubmit, occurredAt: now, sessionId: "s", turnId: "t", cwd: "/tmp/repo", status: .running, terminal: .init(kind: .unknown))
    store.apply(running)
    store.apply(running)
    #expect(store.sessions.count == 1)
    let old = MonitorEvent(eventId: "old", eventType: .agentTurnComplete, occurredAt: now.addingTimeInterval(-1), sessionId: "s", turnId: "t", cwd: "/tmp/repo", status: .ready, terminal: .init(kind: .unknown))
    store.apply(old)
    #expect(store.sessions.first?.status == .running)
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
    store.apply(.init(eventType: .stop, occurredAt: now, sessionId: "done", turnId: "turn-1", cwd: "/tmp/done", status: .ready, terminal: .init(kind: .unknown)))
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
    store.apply(.init(eventType: .stop, occurredAt: now, sessionId: "session", turnId: "turn-1", cwd: "/tmp/repo", status: .ready, terminal: .init(kind: .unknown)))
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
    initialStore.apply(.init(eventType: .stop, occurredAt: now, sessionId: "done", cwd: "/tmp/done", status: .ready, terminal: .init(kind: .unknown)))
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
