import Foundation
import AgentMonitorShared

enum HookInputDecoder {
    private struct HookPayload: Decodable {
        var sessionId: String
        var cwd: String
        var transcriptPath: String?
        var hookEventName: String
        var turnId: String?
        var toolName: String?
        var toolUseID: String?
        var notificationType: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cwd
            case transcriptPath = "transcript_path"
            case hookEventName = "hook_event_name"
            case turnId = "turn_id"
            case toolName = "tool_name"
            case toolUseID = "tool_use_id"
            case notificationType = "notification_type"
        }
    }

    private struct NotifyPayload: Decodable {
        var type: String
        var threadId: String
        var turnId: String?
        var cwd: String

        enum CodingKeys: String, CodingKey {
            case type
            case threadId = "thread-id"
            case turnId = "turn-id"
            case cwd
        }
    }

    static func decodeCodexHook(_ data: Data, terminal: TerminalHost) throws -> MonitorEvent {
        let payload = try JSONDecoder().decode(HookPayload.self, from: data)
        let mapping: (MonitorEventType, SessionStatus)
        switch payload.hookEventName.lowercased() {
        case "sessionstart": mapping = (.sessionStart, .ready)
        case "userpromptsubmit": mapping = (.userPromptSubmit, .running)
        case "posttooluse": mapping = (.postToolUse, .running)
        case "stop": mapping = (.stop, .stale)
        case "interrupt": mapping = (.interrupt, .stale)
        case "permissionrequest": mapping = (.permissionRequested, .attention)
        case "pretooluse" where payload.toolName == "request_user_input": mapping = (.inputRequested, .attention)
        case "sessionend": mapping = (.sessionEnd, .closed)
        default: throw DecodeError.unsupportedEvent(payload.hookEventName)
        }
        return MonitorEvent(
            provider: .codex,
            eventType: mapping.0,
            sessionId: payload.sessionId,
            turnId: payload.turnId,
            cwd: payload.cwd,
            transcriptPath: payload.transcriptPath,
            status: mapping.1,
            terminal: terminal,
            toolName: payload.toolName,
            toolUseID: payload.toolUseID,
            attentionReason: mapping.0 == .permissionRequested ? "Waiting for permission" : mapping.0 == .inputRequested ? "Waiting for input" : nil
        )
    }

    static func decodeCodexNotification(_ data: Data, terminal: TerminalHost) throws -> MonitorEvent {
        let payload = try JSONDecoder().decode(NotifyPayload.self, from: data)
        guard payload.type == "agent-turn-complete" else { throw DecodeError.unsupportedEvent(payload.type) }
        return MonitorEvent(
            provider: .codex,
            eventType: .agentTurnComplete,
            sessionId: payload.threadId,
            turnId: payload.turnId,
            cwd: payload.cwd,
            status: .ready,
            terminal: terminal
        )
    }

    static func decodeClaudeHook(_ data: Data, terminal: TerminalHost) throws -> MonitorEvent {
        let payload = try JSONDecoder().decode(HookPayload.self, from: data)
        let mapping: (MonitorEventType, SessionStatus, String?)
        switch payload.hookEventName.lowercased() {
        case "sessionstart": mapping = (.sessionStart, .ready, nil)
        case "userpromptsubmit": mapping = (.userPromptSubmit, .running, nil)
        case "posttooluse", "posttoolusefailure": mapping = (.postToolUse, .running, nil)
        case "permissionrequest" where payload.toolName == "AskUserQuestion": mapping = (.inputRequested, .attention, "Waiting for input")
        case "permissionrequest": mapping = (.permissionRequested, .attention, "Waiting for permission")
        case "pretooluse" where payload.toolName == "AskUserQuestion": mapping = (.inputRequested, .attention, "Waiting for input")
        case "notification" where payload.notificationType == "permission_prompt": mapping = (.permissionRequested, .attention, "Waiting for permission")
        case "stop": mapping = (.stop, .ready, nil)
        case "sessionend": mapping = (.sessionEnd, .closed, nil)
        default: throw DecodeError.unsupportedEvent(payload.hookEventName)
        }
        return MonitorEvent(
            provider: .claude,
            eventType: mapping.0,
            sessionId: payload.sessionId,
            turnId: payload.turnId,
            cwd: payload.cwd,
            transcriptPath: payload.transcriptPath,
            status: mapping.1,
            terminal: terminal,
            toolName: payload.toolName,
            toolUseID: payload.toolUseID,
            attentionReason: mapping.2
        )
    }

    enum DecodeError: LocalizedError {
        case unsupportedEvent(String)
        var errorDescription: String? {
            switch self { case let .unsupportedEvent(name): "Unsupported agent event: \(name)" }
        }
    }
}

enum CodexSessionInspector {
    static func isUserSession(threadID: String, sessionsRoot: URL? = nil) -> Bool {
        sessionOrigin(threadID: threadID, sessionsRoot: sessionsRoot) == .user
    }

    static func isSubagent(threadID: String, sessionsRoot: URL? = nil) -> Bool {
        sessionOrigin(threadID: threadID, sessionsRoot: sessionsRoot) == .subagent
    }

    private enum SessionOrigin {
        case user
        case subagent
        case unknown
    }

    private static func sessionOrigin(threadID: String, sessionsRoot: URL?) -> SessionOrigin {
        guard threadID.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return .unknown }
        let root = sessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return .unknown }
        let suffix = "-\(threadID).jsonl"
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(suffix) {
            guard let handle = FileHandle(forReadingAtPath: url.path) else { return .unknown }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 256 * 1024),
                  let text = String(data: data, encoding: .utf8) else { return .unknown }
            for line in text.split(separator: "\n").prefix(8) {
                guard let lineData = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      object["type"] as? String == "session_meta",
                      let payload = object["payload"] as? [String: Any],
                      payload["id"] as? String == threadID else { continue }
                if payload["thread_source"] as? String == "subagent"
                    || (payload["source"] as? [String: Any])?["subagent"] != nil {
                    return .subagent
                }
                return .user
            }
            return .unknown
        }
        return .unknown
    }
}
