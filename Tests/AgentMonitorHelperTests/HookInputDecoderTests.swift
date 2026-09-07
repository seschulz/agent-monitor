import Foundation
import Testing
import AgentMonitorShared
#if SWIFT_PACKAGE
@testable import AgentMonitorHelper
#endif

@Test func decodesCodexPermissionRequestsWithoutPrivateInput() throws {
    let json = #"{"session_id":"session-1","turn_id":"turn-1","cwd":"/tmp/repo","hook_event_name":"PermissionRequest","tool_use_id":"call-1","reason":"private reason","tool_input":{"command":"private command"}}"#
    let event = try HookInputDecoder.decodeCodexHook(Data(json.utf8), terminal: .init(kind: .terminalApp))
    #expect(event.status == .attention)
    #expect(event.attentionReason == "Waiting for permission")
    #expect(event.toolUseID == "call-1")
    #expect(!String(data: try JSONEncoder.monitorEncoder.encode(event), encoding: .utf8)!.contains("private"))
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

@Test func decodesClaudePermissionNotificationsButIgnoresIdleAndUnrelatedNotifications() throws {
    let json = #"{"session_id":"claude-session","cwd":"/tmp/repo","hook_event_name":"Notification","notification_type":"permission_prompt","message":"private question"}"#
    let event = try HookInputDecoder.decodeClaudeHook(Data(json.utf8), terminal: .init(kind: .intellij))
    #expect(event.status == .attention)
    #expect(event.attentionReason == "Waiting for permission")
    #expect(!String(data: try JSONEncoder.monitorEncoder.encode(event), encoding: .utf8)!.contains("private"))
    for type in ["idle_prompt", "auth_success", "agent_completed"] {
        #expect(throws: HookInputDecoder.DecodeError.self) {
            try HookInputDecoder.decodeClaudeHook(Data(json.replacingOccurrences(of: "permission_prompt", with: type).utf8), terminal: .init(kind: .unknown))
        }
    }
}

@Test func inputPromptsUseOnlyExplicitQuestionTools() throws {
    for (provider, tool) in [(AgentProvider.codex, "request_user_input"), (.claude, "AskUserQuestion")] {
        let json = #"{"session_id":"s","cwd":"/tmp/repo","hook_event_name":"PreToolUse","tool_name":"TOOL","tool_use_id":"question-1","tool_input":{"questions":["private question"]}}"#.replacingOccurrences(of: "TOOL", with: tool)
        let decode = provider == .codex ? HookInputDecoder.decodeCodexHook : HookInputDecoder.decodeClaudeHook
        let event = try decode(Data(json.utf8), .init(kind: .unknown))
        #expect(event.eventType == .inputRequested)
        #expect(event.attentionReason == "Waiting for input")
        #expect(event.toolUseID == "question-1")
        if provider == .claude {
            let permission = try decode(Data(json.replacingOccurrences(of: "PreToolUse", with: "PermissionRequest").utf8), .init(kind: .unknown))
            #expect(permission.attentionReason == "Waiting for input")
        }
        #expect(!String(data: try JSONEncoder.monitorEncoder.encode(event), encoding: .utf8)!.contains("private"))
        #expect(throws: HookInputDecoder.DecodeError.self) {
            try decode(Data(json.replacingOccurrences(of: tool, with: "Bash").utf8), .init(kind: .unknown))
        }
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
@Test func detectsArbitraryCodeForkFromMainBundleRatherThanInheritedEnvironment() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = root.appendingPathComponent("Future Editor.app/Contents")
    let resources = contents.appendingPathComponent("Resources/app")
    try FileManager.default.createDirectory(at: resources.appendingPathComponent("out/vs/workbench"), withIntermediateDirectories: true)
    let info = ["CFBundleIdentifier": "com.example.future-editor", "CFBundleExecutable": "Electron"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    try Data(#"{"applicationName":"future-editor","urlProtocol":"future-editor"}"#.utf8)
        .write(to: resources.appendingPathComponent("product.json"))
    let executable = contents.appendingPathComponent("MacOS/Electron").path
    let chain: [HostDetector.ProcessRow] = [
        .init(pid: 11, parentPID: 22, startedAt: nil, command: "zsh (kiro-cli-term)", executablePath: "/usr/local/bin/kiro-cli-term"),
        .init(pid: 22, parentPID: 33, startedAt: nil, command: "Electron Helper", executablePath: contents.appendingPathComponent("Frameworks/Electron Helper.app/Contents/MacOS/Electron Helper").path),
        .init(pid: 33, parentPID: 1, startedAt: Date(timeIntervalSince1970: 100), command: executable, executablePath: executable)
    ]
    let host = HostDetector.classify(chain: chain, environmentBundleID: "com.jetbrains.intellij")
    #expect(host.kind == .vscode)
    #expect(host.bundleID == "com.example.future-editor")
    #expect(host.pid == 33)
    #expect(host.startedAt == Date(timeIntervalSince1970: 100))
    #expect(HostDetector.isShellCommand(chain[0].command))
    #expect(HostDetector.codeEditorBundleIdentifier(executable: contents.appendingPathComponent("MacOS/Other")) == nil)
    // An Electron bundle alone is not evidence of a Code workbench.
    try FileManager.default.removeItem(at: resources.appendingPathComponent("out/vs/workbench"))
    #expect(HostDetector.codeEditorBundleIdentifier(executable: URL(fileURLWithPath: executable)) == nil)
}

@Test func detectsRiderMainProcessDespiteBackendAndInheritedIntelliJEnvironment() {
    let start = Date(timeIntervalSince1970: 1000)
    let chain: [HostDetector.ProcessRow] = [
        .init(pid: 10, parentPID: 20, startedAt: start, command: "/bin/zsh -c echo idea", executablePath: "/bin/zsh"),
        .init(pid: 20, parentPID: 25, startedAt: start, command: "Rider.Backend", executablePath: "/Applications/Rider.app/Contents/lib/ReSharperHost/macos-arm64/Rider.Backend"),
        .init(pid: 25, parentPID: 30, startedAt: start, command: "/Applications/Rider.app/Contents/MacOS/rider stdioMcpServer", executablePath: "/Applications/Rider.app/Contents/MacOS/rider"),
        .init(pid: 30, parentPID: 40, startedAt: start, command: "rider", executablePath: "/Applications/Rider.app/Contents/MacOS/rider"),
        .init(pid: 40, parentPID: 1, startedAt: start, command: "idea", executablePath: "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea")
    ]
    let host = HostDetector.classify(chain: chain, environmentBundleID: "com.jetbrains.intellij")
    #expect(host.kind == .rider)
    #expect(host.bundleID == "com.jetbrains.rider")
    #expect(host.pid == 30)
    #expect(host.startedAt == start)
}

@Test func detectsToolboxRiderAndPreservesIntelliJDetection() {
    for (path, kind, bundleID) in [
        ("/Users/me/Library/Application Support/JetBrains/Toolbox/apps/Rider 2026.2 EAP.app/Contents/MacOS/rider", TerminalKind.rider, "com.jetbrains.rider"),
        ("/Applications/IntelliJ IDEA.app/Contents/MacOS/idea", TerminalKind.intellij, "com.jetbrains.intellij")
    ] {
        let chain = [HostDetector.ProcessRow(pid: 30, parentPID: 1, startedAt: nil, command: path, executablePath: path)]
        let host = HostDetector.classify(chain: chain, environmentBundleID: nil)
        #expect(host.kind == kind)
        #expect(host.bundleID == bundleID)
        #expect(host.pid == 30)
    }
}

@Test func riderBackendAndCommandArgumentsAreNotIDEWindows() {
    let chain: [HostDetector.ProcessRow] = [
        .init(pid: 10, parentPID: 20, startedAt: nil, command: "/bin/zsh -c /Applications/Rider.app/Contents/MacOS/rider", executablePath: "/bin/zsh"),
        .init(pid: 20, parentPID: 1, startedAt: nil, command: "Rider.Backend", executablePath: "/Applications/Rider.app/Contents/lib/ReSharperHost/macos-arm64/Rider.Backend")
    ]
    #expect(HostDetector.classify(chain: chain, environmentBundleID: nil).kind == .unknown)
}

@Test func identifiesCodexProcessWithoutMistakingHookRunner() {
    #expect(HostDetector.isCodexCommand("/opt/homebrew/bin/codex exec"))
    #expect(HostDetector.isCodexCommand("node /usr/local/bin/codex --version"))
    #expect(!HostDetector.isCodexCommand("/bin/zsh -c /Applications/AgentMonitor.app/agent-monitor-helper"))
}

@Test func identifiesShellExecutablesWithoutMatchingCommandArguments() {
    #expect(HostDetector.isShellCommand("/bin/zsh -l"))
    #expect(HostDetector.isShellCommand("-bash"))
    #expect(HostDetector.isShellCommand("/opt/homebrew/bin/fish"))
    #expect(!HostDetector.isShellCommand("node /tmp/bash/script.js"))
    #expect(!HostDetector.isShellCommand("codex --shell zsh"))
}

@Test func identifiesClaudeProcessWithoutMistakingHookRunner() {
    #expect(HostDetector.isClaudeCommand("/Users/me/.local/bin/claude"))
    #expect(HostDetector.isClaudeCommand("node /usr/local/bin/claude-code"))
    #expect(!HostDetector.isClaudeCommand("/bin/zsh -c agent-monitor-helper claude-hook"))
}
#endif

@Test func codexInterruptIsDistinctFromStopWhileWaitingForInput() throws {
    let json = #"{"session_id":"s","cwd":"/tmp/repo","hook_event_name":"Interrupt"}"#
    let event = try HookInputDecoder.decodeCodexHook(Data(json.utf8), terminal: .init(kind: .unknown))
    #expect(event.eventType == .interrupt)
    #expect(event.status == .stale)
}
