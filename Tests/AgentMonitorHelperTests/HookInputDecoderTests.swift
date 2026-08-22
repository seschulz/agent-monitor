import Foundation
import Testing
import AgentMonitorShared
#if SWIFT_PACKAGE
@testable import AgentMonitorHelper
#endif

@Test func ignoresCodexPermissionRequests() throws {
    let json = #"{"session_id":"session-1","turn_id":"turn-1","cwd":"/tmp/repo","hook_event_name":"PermissionRequest","reason":"Run tests","prompt":"private"}"#
    #expect(throws: HookInputDecoder.DecodeError.self) {
        try HookInputDecoder.decodeCodexHook(Data(json.utf8), terminal: .init(kind: .terminalApp, tty: "/dev/ttys001"))
    }
}

@Test func decodesCompletionNotification() throws {
    let json = #"{"type":"agent-turn-complete","thread-id":"session-1","turn-id":"turn-1","cwd":"/tmp/repo","last-assistant-message":"private"}"#
    let event = try HookInputDecoder.decodeCodexNotification(Data(json.utf8), terminal: .init(kind: .unknown))
    #expect(event.status == .ready)
    #expect(event.eventType == .agentTurnComplete)
}

@Test func ignoresClaudeNotifications() throws {
    let json = #"{"session_id":"claude-session","cwd":"/tmp/repo","hook_event_name":"Notification","notification_type":"permission_prompt","message":"private question"}"#
    #expect(throws: HookInputDecoder.DecodeError.self) {
        try HookInputDecoder.decodeClaudeHook(Data(json.utf8), terminal: .init(kind: .intellij))
    }
}

@Test func decodesClaudeStopAsReady() throws {
    let json = #"{"session_id":"claude-session","cwd":"/tmp/repo","hook_event_name":"Stop"}"#
    let event = try HookInputDecoder.decodeClaudeHook(Data(json.utf8), terminal: .init(kind: .unknown))

    #expect(event.provider == .claude)
    #expect(event.status == .ready)
    #expect(event.eventType == .stop)
}

#if SWIFT_PACKAGE
@Test func identifiesCodexProcessWithoutMistakingHookRunner() {
    #expect(HostDetector.isCodexCommand("/opt/homebrew/bin/codex exec"))
    #expect(HostDetector.isCodexCommand("node /usr/local/bin/codex --version"))
    #expect(!HostDetector.isCodexCommand("/bin/zsh -c /Applications/AgentMonitor.app/agent-monitor-helper"))
}

@Test func identifiesClaudeProcessWithoutMistakingHookRunner() {
    #expect(HostDetector.isClaudeCommand("/Users/me/.local/bin/claude"))
    #expect(HostDetector.isClaudeCommand("node /usr/local/bin/claude-code"))
    #expect(!HostDetector.isClaudeCommand("/bin/zsh -c agent-monitor-helper claude-hook"))
}
#endif
