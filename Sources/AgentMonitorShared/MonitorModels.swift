import Foundation
import Darwin

public enum ProcessIdentity {
    /// Some JetBrains applications have no NSRunningApplication launchDate.
    /// Read the kernel's timestamp so those hosts still get PID-reuse checks.
    public static func startedAt(pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_uid == getuid(), info.pbi_start_tvsec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
}

/// Identifies a live terminal shell, including its lifetime so a reused PID or
/// device name cannot redirect a completed session into a different terminal.
public struct TerminalShellIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startedAt: Date
    public let tty: String

    public init(pid: Int32, startedAt: Date, tty: String) {
        self.pid = pid
        self.startedAt = startedAt
        self.tty = tty
    }

    public var key: String { "terminal:\(pid):\(startedAt.timeIntervalSince1970.rounded(.down)):\(tty)" }

    public func matches(_ other: TerminalShellIdentity) -> Bool {
        pid == other.pid && tty == other.tty && abs(startedAt.timeIntervalSince(other.startedAt)) < 1
    }

    public static func read(pid: Int32) -> TerminalShellIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_uid == getuid(), info.e_tdev != UInt32.max,
              let name = devname(Int32(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        let tty = "/dev/" + String(cString: name)
        guard isConcreteTTY(tty) else { return nil }
        return .init(pid: pid, startedAt: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec)), tty: tty)
    }

    public static func isConcreteTTY(_ path: String) -> Bool {
        guard path.hasPrefix("/dev/ttys") else { return false }
        let suffix = path.dropFirst("/dev/ttys".count)
        return !suffix.isEmpty && suffix.count <= 16 && suffix.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    public func isLive(inHost hostPID: Int32) -> Bool {
        guard let current = Self.read(pid: pid), matches(current) else { return false }
        var ancestor = pid
        for _ in 0..<32 {
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.stride
            guard proc_pidinfo(ancestor, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return false }
            let parent = Int32(info.pbi_ppid)
            if parent == hostPID { return true }
            guard parent > 1, parent != ancestor else { return false }
            ancestor = parent
        }
        return false
    }
}

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
    case rider
    case vscode
    case unknown

    public var isJetBrains: Bool { self == .intellij || self == .rider }
}

public struct TerminalHost: Codable, Equatable, Sendable {
    public var kind: TerminalKind
    public var bundleIdentifier: String?
    public var hostPid: Int32?
    public var agentPid: Int32?
    public var tty: String?
    public var processStartedAt: Date?
    public var shell: TerminalShellIdentity?

    public init(
        kind: TerminalKind,
        bundleIdentifier: String? = nil,
        hostPid: Int32? = nil,
        agentPid: Int32? = nil,
        tty: String? = nil,
        processStartedAt: Date? = nil,
        shell: TerminalShellIdentity? = nil
    ) {
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.hostPid = hostPid
        self.agentPid = agentPid
        self.tty = tty
        self.processStartedAt = processStartedAt
        self.shell = shell
    }

}

public enum MonitorEventType: String, Codable, Sendable {
    case sessionStart
    case userPromptSubmit
    case postToolUse
    case permissionRequested
    case inputRequested
    case agentTurnComplete
    case stop
    case interrupt
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
    public var transcriptPath: String?
    public var status: SessionStatus
    public var terminal: TerminalHost
    public var toolName: String?
    public var toolUseID: String?
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
        transcriptPath: String? = nil,
        status: SessionStatus,
        terminal: TerminalHost,
        toolName: String? = nil,
        toolUseID: String? = nil,
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
        self.transcriptPath = transcriptPath
        self.status = status
        self.terminal = terminal
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.attentionReason = attentionReason
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw MonitorEventError.unsupportedSchema }
        guard !eventId.isEmpty, eventId.count <= 128 else { throw MonitorEventError.invalidEventID }
        guard !sessionId.isEmpty, sessionId.count <= 512 else { throw MonitorEventError.invalidSessionID }
        guard !cwd.isEmpty, cwd.count <= 4096 else { throw MonitorEventError.invalidWorkingDirectory }
        guard turnId?.count ?? 0 <= 512,
              transcriptPath?.count ?? 0 <= 4096,
              terminal.tty?.count ?? 0 <= 1024,
              terminal.bundleIdentifier?.count ?? 0 <= 512,
              terminal.shell?.tty.count ?? 0 <= 1024,
              toolUseID?.count ?? 0 <= 512,
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
    public var transcriptPath: String?
    public var displayName: String
    public var terminal: TerminalHost
    public var startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var attentionReason: String?
    public var dismissedAt: Date?
    public var attentionToolUseID: String?

    public init(event: MonitorEvent) {
        id = event.scopedSessionID
        provider = event.provider
        currentTurnId = event.turnId
        status = event.status
        cwd = event.cwd
        transcriptPath = event.transcriptPath
        displayName = URL(fileURLWithPath: event.cwd).lastPathComponent.isEmpty
            ? "\(event.provider.displayName) session"
            : URL(fileURLWithPath: event.cwd).lastPathComponent
        terminal = event.terminal
        startedAt = event.occurredAt
        updatedAt = event.occurredAt
        completedAt = event.status == .ready ? event.occurredAt : nil
        attentionReason = event.attentionReason
        attentionToolUseID = event.status == .attention ? event.toolUseID : nil
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
