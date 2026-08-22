import Foundation
import AgentMonitorShared

private let version = "1.0.0"

func report(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func deliver(_ event: MonitorEvent) {
    do {
        try SocketClient.send(event)
    } catch {
        // A hook must respect an explicit Quit. Retry briefly in case the app is
        // already launching, but never launch it on behalf of an agent session.
        usleep(150_000)
        do { try SocketClient.send(event) } catch { report("Agent Monitor unavailable: \(error.localizedDescription)") }
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    report("Usage: agent-monitor-helper <codex-hook|codex-notify|claude-hook|doctor|version>")
    exit(64)
}

do {
    switch arguments[1] {
    case "version", "--version":
        print("agent-monitor-helper \(version)")
    case "doctor":
        print("Helper: \(version)")
        print("Socket: \(SocketClient.socketPath)")
        print("App: \(FileManager.default.fileExists(atPath: SocketClient.socketPath) ? "listening" : "not running")")
        let host = HostDetector.detect(provider: nil)
        print("Terminal: \(host.kind.rawValue) \(host.tty ?? "no TTY")")
    case "codex-hook":
        let input = FileHandle.standardInput.readDataToEndOfFile()
        deliver(try HookInputDecoder.decodeCodexHook(input, terminal: HostDetector.detect(provider: .codex)))
    case "codex-notify":
        guard arguments.count >= 3 else { throw CLIError.missingNotification }
        deliver(try HookInputDecoder.decodeCodexNotification(Data(arguments[2].utf8), terminal: HostDetector.detect(provider: .codex)))
    case "claude-hook":
        let input = FileHandle.standardInput.readDataToEndOfFile()
        deliver(try HookInputDecoder.decodeClaudeHook(input, terminal: HostDetector.detect(provider: .claude)))
    default:
        throw CLIError.unknownCommand(arguments[1])
    }
} catch {
    report(error.localizedDescription)
    // Hook failures must not interrupt the agent.
    exit(0)
}

enum CLIError: LocalizedError {
    case missingNotification, unknownCommand(String)
    var errorDescription: String? {
        switch self {
        case .missingNotification: "codex-notify expects one JSON argument"
        case let .unknownCommand(command): "Unknown command: \(command)"
        }
    }
}
