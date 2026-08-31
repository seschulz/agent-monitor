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

@Test func decodesCodexStopAsInactiveWithoutCompleting() throws {
    let json = #"{"session_id":"session-1","turn_id":"turn-1","cwd":"/tmp/repo","transcript_path":"/tmp/rollout.jsonl","hook_event_name":"Stop"}"#
    let event = try HookInputDecoder.decodeCodexHook(Data(json.utf8), terminal: .init(kind: .unknown))

    #expect(event.provider == .codex)
    #expect(event.eventType == .stop)
    #expect(event.status == .stale)
    #expect(event.transcriptPath == "/tmp/rollout.jsonl")
}

@Test func identifiesCodexSubagentFromSessionMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directory = root.appendingPathComponent("2026/08/25")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let threadID = "01a039d7-a242-7223-8a88-a664ade364bd"
    let transcript = directory.appendingPathComponent("rollout-2026-08-25T18-53-48-\(threadID).jsonl")
    try #"{"type":"session_meta","payload":{"id":"01a039d7-a242-7223-8a88-a664ade364bd","thread_source":"subagent","source":{"subagent":{}}}}"#
        .write(to: transcript, atomically: true, encoding: .utf8)

    #expect(CodexSessionInspector.isSubagent(threadID: threadID, sessionsRoot: root))
    #expect(!CodexSessionInspector.isUserSession(threadID: threadID, sessionsRoot: root))
}

@Test func doesNotIdentifyUserCodexThreadAsSubagent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let threadID = "01a039d7-7506-7b31-ab3b-31617a637ad6"
    let transcript = root.appendingPathComponent("rollout-\(threadID).jsonl")
    try #"{"type":"session_meta","payload":{"id":"01a039d7-7506-7b31-ab3b-31617a637ad6","thread_source":"user","source":"cli"}}"#
        .write(to: transcript, atomically: true, encoding: .utf8)

    #expect(!CodexSessionInspector.isSubagent(threadID: threadID, sessionsRoot: root))
    #expect(CodexSessionInspector.isUserSession(threadID: threadID, sessionsRoot: root))
}

@Test func rejectsCompletionForCodexThreadWithoutTranscript() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(!CodexSessionInspector.isUserSession(
        threadID: "019d434e-6032-76b3-b32f-cb4622fecbba",
        sessionsRoot: root
    ))
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
