import Foundation
import Testing
@testable import AgentMonitorShared

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
