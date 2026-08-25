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

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cwd
            case transcriptPath = "transcript_path"
            case hookEventName = "hook_event_name"
            case turnId = "turn_id"
            case toolName = "tool_name"
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
            attentionReason: nil
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
        case "posttooluse": mapping = (.postToolUse, .running, nil)
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
    static func isSubagent(threadID: String, sessionsRoot: URL? = nil) -> Bool {
        guard threadID.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return false }
        let root = sessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        let suffix = "-\(threadID).jsonl"
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(suffix) {
            guard let handle = FileHandle(forReadingAtPath: url.path) else { return false }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 256 * 1024),
                  let text = String(data: data, encoding: .utf8) else { return false }
            for line in text.split(separator: "\n").prefix(8) {
                guard let lineData = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      object["type"] as? String == "session_meta",
                      let payload = object["payload"] as? [String: Any],
                      payload["id"] as? String == threadID else { continue }
                if payload["thread_source"] as? String == "subagent" { return true }
                return (payload["source"] as? [String: Any])?["subagent"] != nil
            }
            return false
        }
        return false
    }
}
