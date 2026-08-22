import Darwin
import Foundation
import AgentMonitorShared

enum HostDetector {
    private struct ProcessRow {
        let pid: Int32
        let parentPID: Int32
        let startedAt: Date?
        let command: String
    }

    static func detect(provider: AgentProvider?) -> TerminalHost {
        let parentPID = getppid()
        let tty = controllingTTY()
        let environmentBundleID = ProcessInfo.processInfo.environment["__CFBundleIdentifier"]
        let chain = processChain(from: parentPID)
        let agentPID = chain.first(where: { row in
            switch provider {
            case .codex: isCodexCommand(row.command)
            case .claude: isClaudeCommand(row.command)
            case nil: isCodexCommand(row.command) || isClaudeCommand(row.command)
            }
        })?.pid
        let classified = classify(chain: chain, environmentBundleID: environmentBundleID)
        return TerminalHost(
            kind: classified.kind,
            bundleIdentifier: classified.bundleID ?? environmentBundleID,
            hostPid: classified.pid,
            agentPid: agentPID,
            tty: tty,
            processStartedAt: classified.startedAt
        )
    }

    static func isCodexCommand(_ command: String) -> Bool {
        command.split(whereSeparator: { $0.isWhitespace }).prefix(3).contains { token in
            let name = URL(fileURLWithPath: String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))).lastPathComponent.lowercased()
            return name == "codex"
                || name.hasPrefix("codex-aarch64")
                || name.hasPrefix("codex-x86_64")
        }
    }

    static func isClaudeCommand(_ command: String) -> Bool {
        command.split(whereSeparator: { $0.isWhitespace }).prefix(4).contains { token in
            let name = URL(fileURLWithPath: String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))).lastPathComponent.lowercased()
            return name == "claude" || name == "claude-code"
        }
    }

    private static func controllingTTY() -> String? {
        let descriptor = open("/dev/tty", O_RDONLY | O_NOCTTY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard let name = ttyname(descriptor) else { return nil }
        return String(cString: name)
    }

    private static func processChain(from startPID: Int32) -> [ProcessRow] {
        var result: [ProcessRow] = []
        var pid = startPID
        for _ in 0..<32 where pid > 1 {
            guard let row = processRow(pid: pid) else { break }
            result.append(row)
            guard row.parentPID != pid else { break }
            pid = row.parentPID
        }
        return result
    }

    private static func processRow(pid: Int32) -> ProcessRow? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "ppid=", "-o", "lstart=", "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard let line = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return nil }
        let parts = line.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 7, let parent = Int32(parts[0]) else { return nil }
        let timestamp = parts[1...5].joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return ProcessRow(pid: pid, parentPID: parent, startedAt: formatter.date(from: timestamp), command: parts[6...].joined(separator: " "))
    }

    private static func classify(chain: [ProcessRow], environmentBundleID: String?) -> (kind: TerminalKind, bundleID: String?, pid: Int32?, startedAt: Date?) {
        let candidates: [(TerminalKind, String, [String])] = [
            (.intellij, "com.jetbrains.intellij", ["IntelliJ IDEA", "idea"]),
            (.iTerm2, "com.googlecode.iterm2", ["iTerm2", "iTerm.app"]),
            (.terminalApp, "com.apple.Terminal", ["Terminal.app"]),
            (.ghostty, "com.mitchellh.ghostty", ["Ghostty.app", "ghostty"])
        ]
        for candidate in candidates {
            if environmentBundleID == candidate.1,
               let row = chain.first(where: { candidate.2.contains(where: $0.command.localizedCaseInsensitiveContains) }) {
                return (candidate.0, candidate.1, row.pid, row.startedAt)
            }
        }
        for row in chain {
            if let candidate = candidates.first(where: { item in item.2.contains(where: row.command.localizedCaseInsensitiveContains) }) {
                return (candidate.0, candidate.1, row.pid, row.startedAt)
            }
        }
        if let bundleID = environmentBundleID,
           let candidate = candidates.first(where: { $0.1 == bundleID }) {
            return (candidate.0, candidate.1, chain.last?.pid, chain.last?.startedAt)
        }
        return (.unknown, environmentBundleID, chain.last?.pid, chain.last?.startedAt)
    }
}
