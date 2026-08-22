import Foundation

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case running
    case attention
    case ready
    case stale
    case closed
}

public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

public enum TerminalKind: String, Codable, CaseIterable, Sendable {
    case terminalApp
    case iTerm2
    case ghostty
    case intellij
    case unknown
}

public struct TerminalHost: Codable, Equatable, Sendable {
    public var kind: TerminalKind
    public var bundleIdentifier: String?
    public var hostPid: Int32?
    public var agentPid: Int32?
    public var tty: String?
    public var processStartedAt: Date?

    public init(
        kind: TerminalKind,
        bundleIdentifier: String? = nil,
        hostPid: Int32? = nil,
        agentPid: Int32? = nil,
        tty: String? = nil,
        processStartedAt: Date? = nil
    ) {
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.hostPid = hostPid
        self.agentPid = agentPid
        self.tty = tty
        self.processStartedAt = processStartedAt
    }

}

public enum MonitorEventType: String, Codable, Sendable {
    case sessionStart
    case userPromptSubmit
    case postToolUse
    case permissionRequested
    case agentTurnComplete
    case stop
    case sessionEnd
}

public struct MonitorEvent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumWireSize = 256 * 1024

    public var schemaVersion: Int
    public var provider: AgentProvider
    public var eventId: String
    public var eventType: MonitorEventType
    public var occurredAt: Date
    public var sessionId: String
    public var turnId: String?
    public var cwd: String
    public var status: SessionStatus
    public var terminal: TerminalHost
    public var toolName: String?
    public var attentionReason: String?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        provider: AgentProvider = .codex,
        eventId: String = UUID().uuidString,
        eventType: MonitorEventType,
        occurredAt: Date = Date(),
        sessionId: String,
        turnId: String? = nil,
        cwd: String,
        status: SessionStatus,
        terminal: TerminalHost,
        toolName: String? = nil,
        attentionReason: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.eventId = eventId
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.sessionId = sessionId
        self.turnId = turnId
        self.cwd = cwd
        self.status = status
        self.terminal = terminal
        self.toolName = toolName
        self.attentionReason = attentionReason
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw MonitorEventError.unsupportedSchema }
        guard !eventId.isEmpty, eventId.count <= 128 else { throw MonitorEventError.invalidEventID }
        guard !sessionId.isEmpty, sessionId.count <= 512 else { throw MonitorEventError.invalidSessionID }
        guard !cwd.isEmpty, cwd.count <= 4096 else { throw MonitorEventError.invalidWorkingDirectory }
        guard turnId?.count ?? 0 <= 512,
              terminal.tty?.count ?? 0 <= 1024,
              terminal.bundleIdentifier?.count ?? 0 <= 512,
              attentionReason?.count ?? 0 <= 1024 else {
            throw MonitorEventError.fieldTooLong
        }
    }
}

public enum MonitorEventError: LocalizedError {
    case unsupportedSchema
    case invalidEventID
    case invalidSessionID
    case invalidWorkingDirectory
    case fieldTooLong
    case messageTooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "Unsupported event schema"
        case .invalidEventID: "Invalid event ID"
        case .invalidSessionID: "Invalid session ID"
        case .invalidWorkingDirectory: "Invalid working directory"
        case .fieldTooLong: "Event field exceeds its size limit"
        case .messageTooLarge: "Event exceeds 256 KiB"
        }
    }
}

public struct SessionRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var provider: AgentProvider
    public var currentTurnId: String?
    public var status: SessionStatus
    public var cwd: String
    public var displayName: String
    public var terminal: TerminalHost
    public var startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var attentionReason: String?
    public var dismissedAt: Date?

    public init(event: MonitorEvent) {
        id = event.scopedSessionID
        provider = event.provider
        currentTurnId = event.turnId
        status = event.status
        cwd = event.cwd
        displayName = URL(fileURLWithPath: event.cwd).lastPathComponent.isEmpty
            ? "\(event.provider.displayName) session"
            : URL(fileURLWithPath: event.cwd).lastPathComponent
        terminal = event.terminal
        startedAt = event.occurredAt
        updatedAt = event.occurredAt
        completedAt = event.status == .ready ? event.occurredAt : nil
        attentionReason = event.attentionReason
        dismissedAt = nil
    }

}

public extension MonitorEvent {
    var scopedSessionID: String { "\(provider.rawValue):\(sessionId)" }
}

public extension JSONEncoder {
    static var monitorEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var monitorDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
