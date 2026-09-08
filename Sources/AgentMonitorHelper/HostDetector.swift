import Darwin
import Foundation
import AgentMonitorShared

enum HostDetector {
    struct ProcessRow {
        let pid: Int32
        let parentPID: Int32
        let startedAt: Date?
        let command: String
        var executablePath: String? = nil
    }

    static func detect(provider: AgentProvider?) -> TerminalHost {
        let parentPID = getppid()
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
        let terminalShell = chain.reversed().first(where: { isShellCommand($0.command) })
            .flatMap { TerminalShellIdentity.read(pid: $0.pid) }
        let tty = terminalShell?.tty ?? TerminalShellIdentity.read(pid: parentPID)?.tty ?? controllingTTY()
        return TerminalHost(
            kind: classified.kind,
            bundleIdentifier: classified.bundleID ?? environmentBundleID,
            hostPid: classified.pid,
            agentPid: agentPID,
            tty: tty,
            processStartedAt: classified.startedAt,
            shell: terminalShell
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

    static func isShellCommand(_ command: String) -> Bool {
        guard let executable = command.split(whereSeparator: { $0.isWhitespace }).first else { return false }
        let name = URL(fileURLWithPath: String(executable)).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh"].contains(name)
    }

    private static func controllingTTY() -> String? {
        let descriptor = open("/dev/tty", O_RDONLY | O_NOCTTY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard let name = ttyname(descriptor) else { return nil }
        let path = String(cString: name)
        return TerminalShellIdentity.isConcreteTTY(path) ? path : nil
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
        do { try process.run() } catch { return nil }
        // A long ancestor command can fill the pipe. Drain it before waiting,
        // otherwise ps blocks on write and the hook waits until Codex kills it.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let line = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else { return nil }
        let parts = line.split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 7, let parent = Int32(parts[0]) else { return nil }
        let timestamp = parts[1...5].joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        // PROC_PIDPATHINFO_MAXSIZE expands to 4 * MAXPATHLEN in libproc;
        // Swift does not import that expression macro.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let executablePath = pathLength > 0
            ? String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : nil
        return ProcessRow(pid: pid, parentPID: parent, startedAt: formatter.date(from: timestamp),
                          command: parts[6...].joined(separator: " "), executablePath: executablePath)
    }

    static func classify(chain: [ProcessRow], environmentBundleID: String?) -> (kind: TerminalKind, bundleID: String?, pid: Int32?, startedAt: Date?) {
        // Prefer actual IDE executables over inherited bundle IDs and command
        // arguments. Rider also spawns backend and browser helper processes.
        for row in chain {
            guard let path = row.executablePath else { continue }
            let executable = URL(fileURLWithPath: path)
            let macOS = executable.deletingLastPathComponent()
            let contents = macOS.deletingLastPathComponent()
            guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
                  contents.deletingLastPathComponent().pathExtension == "app" else { continue }
            let arguments = row.command.hasPrefix(path)
                ? row.command.dropFirst(path.count).split(whereSeparator: { $0.isWhitespace })
                : row.command.split(whereSeparator: { $0.isWhitespace }).dropFirst().map { $0 }
            guard arguments.first != "stdioMcpServer" else { continue }
            if let bundleID = codeEditorBundleIdentifier(executable: executable) {
                return (.vscode, bundleID, row.pid, row.startedAt)
            }
            switch executable.lastPathComponent {
            case "rider": return (.rider, "com.jetbrains.rider", row.pid, row.startedAt)
            case "idea": return (.intellij, "com.jetbrains.intellij", row.pid, row.startedAt)
            default: continue
            }
        }
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

    /// Recognize the shared desktop workbench, not a fixed list of fork names.
    /// Only the bundle's main executable qualifies; Electron helpers do not.
    static func codeEditorBundleIdentifier(executable: URL) -> String? {
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app",
              let infoData = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              info["CFBundleExecutable"] as? String == executable.lastPathComponent,
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        let resources = contents.appendingPathComponent("Resources/app")
        guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("out/vs/workbench").path),
              let data = try? Data(contentsOf: resources.appendingPathComponent("product.json")),
              let product = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = product["applicationName"] as? String, !name.isEmpty,
              let protocolName = product["urlProtocol"] as? String, !protocolName.isEmpty else { return nil }
        return bundleID
    }
}
