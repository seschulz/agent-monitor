import Foundation
import Testing
@testable import AgentMonitorShared

@Test func kernelProcessIdentityDoesNotRequireApplicationLaunchMetadata() throws {
    let pid = ProcessInfo.processInfo.processIdentifier
    let startedAt = try #require(ProcessIdentity.startedAt(pid: pid))
    #expect(startedAt <= Date())
    #expect(ProcessIdentity.startedAt(pid: pid) == startedAt)
    #expect(ProcessIdentity.startedAt(pid: -1) == nil)
    #expect(ProcessIdentity.startedAt(pid: 0) == nil)
}

@Test func terminalIdentityIsSharedAcrossAgentSessionsButNotReusedShells() {
    let original = TerminalShellIdentity(pid: 123, startedAt: Date(timeIntervalSince1970: 1000), tty: "/dev/ttys012")
    let same = TerminalShellIdentity(pid: 123, startedAt: Date(timeIntervalSince1970: 1000), tty: "/dev/ttys012")
    let replacement = TerminalShellIdentity(pid: 123, startedAt: Date(timeIntervalSince1970: 2000), tty: "/dev/ttys012")
    let otherTab = TerminalShellIdentity(pid: 124, startedAt: Date(timeIntervalSince1970: 1000), tty: "/dev/ttys013")
    #expect(original.key == same.key)
    #expect(original.matches(same))
    #expect(!original.matches(replacement))
    #expect(!original.matches(otherTab))
    #expect(original.key != replacement.key)
}

@Test func terminalDeviceValidationRejectsAliasesAndNonDevices() {
    #expect(TerminalShellIdentity.isConcreteTTY("/dev/ttys012"))
    for path in ["/dev/tty", "/dev/ttys", "/dev/ttys012/../tty", "/tmp/ttys012", "/dev/ttys012\n", "/dev/null"] {
        #expect(!TerminalShellIdentity.isConcreteTTY(path))
    }
    #expect(TerminalShellIdentity.read(pid: -1) == nil)
}

@Test func terminalHostDecodesOldEventsAndRoundTripsShellIdentity() throws {
    let legacy = try JSONDecoder.monitorDecoder.decode(TerminalHost.self, from: Data(#"{"kind":"intellij","tty":"/dev/tty"}"#.utf8))
    #expect(legacy.shell == nil)
    let shell = TerminalShellIdentity(pid: 123, startedAt: Date(timeIntervalSince1970: 1000), tty: "/dev/ttys012")
    for kind in [TerminalKind.intellij, .rider, .vscode] {
        let host = TerminalHost(kind: kind, tty: shell.tty, shell: shell)
        #expect(try JSONDecoder.monitorDecoder.decode(TerminalHost.self, from: JSONEncoder.monitorEncoder.encode(host)) == host)
    }
}

@Test func eventRoundTrips() throws {
    let event = MonitorEvent(
        provider: .claude,
        eventType: .permissionRequested,
        sessionId: "thr_123",
        turnId: "turn_456",
        cwd: "/tmp/project",
        status: .attention,
        terminal: TerminalHost(kind: .intellij, tty: "/dev/ttys006"),
        attentionReason: "Approval required"
    )
    let data = try JSONEncoder.monitorEncoder.encode(event)
    let decoded = try JSONDecoder.monitorDecoder.decode(MonitorEvent.self, from: data)
    #expect(decoded.eventId == event.eventId)
    #expect(decoded.provider == .claude)
    #expect(decoded.sessionId == event.sessionId)
    #expect(abs(decoded.occurredAt.timeIntervalSince(event.occurredAt)) < 1)
    try decoded.validate()
}

@Test func providerScopesOtherwiseIdenticalSessionIDs() {
    let terminal = TerminalHost(kind: .unknown)
    let codex = MonitorEvent(provider: .codex, eventType: .sessionStart, sessionId: "same", cwd: "/tmp", status: .ready, terminal: terminal)
    let claude = MonitorEvent(provider: .claude, eventType: .sessionStart, sessionId: "same", cwd: "/tmp", status: .ready, terminal: terminal)

    #expect(codex.scopedSessionID == "codex:same")
    #expect(claude.scopedSessionID == "claude:same")
}

@Test func validationRejectsWrongSchemaAndLongFields() {
    var event = MonitorEvent(eventType: .sessionStart, sessionId: "s", cwd: "/tmp", status: .ready, terminal: .init(kind: .unknown))
    event.schemaVersion = 2
    #expect(throws: MonitorEventError.self) { try event.validate() }
    event.schemaVersion = 1
    event.sessionId = String(repeating: "a", count: 513)
    #expect(throws: MonitorEventError.self) { try event.validate() }
}

@Test func oversizedWirePayloadExceedsLimit() throws {
    let event = MonitorEvent(
        eventType: .permissionRequested,
        sessionId: "s",
        cwd: "/tmp",
        status: .attention,
        terminal: .init(kind: .unknown),
        attentionReason: String(repeating: "x", count: MonitorEvent.maximumWireSize)
    )
    let data = try JSONEncoder.monitorEncoder.encode(event)
    #expect(data.count > MonitorEvent.maximumWireSize)
}
