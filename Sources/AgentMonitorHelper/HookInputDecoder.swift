import Foundation
import AgentMonitorShared

enum HookInputDecoder {
    private struct HookPayload: Decodable {
        var sessionId: String
        var cwd: String
        var hookEventName: String
        var turnId: String?
        var toolName: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cwd
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
        case "stop": mapping = (.stop, .ready)
        case "sessionend": mapping = (.sessionEnd, .closed)
        default: throw DecodeError.unsupportedEvent(payload.hookEventName)
        }
        return MonitorEvent(
            provider: .codex,
            eventType: mapping.0,
            sessionId: payload.sessionId,
            turnId: payload.turnId,
            cwd: payload.cwd,
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
