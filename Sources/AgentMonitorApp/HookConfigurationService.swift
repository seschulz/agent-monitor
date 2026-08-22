import Foundation

struct HookConfigurationPaths {
    let codexHooks: URL
    let codexConfig: URL
    let claudeSettings: URL

    static var userDefaults: HookConfigurationPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return HookConfigurationPaths(
            codexHooks: home.appendingPathComponent(".codex/hooks.json"),
            codexConfig: home.appendingPathComponent(".codex/config.toml"),
            claudeSettings: home.appendingPathComponent(".claude/settings.json")
        )
    }
}

enum HookConfigurationService {
    static let events = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"]
    static let markerBegin = "# BEGIN Agent Monitor"
    static let markerEnd = "# END Agent Monitor"

    static func isInstalled(helperURL: URL, paths: HookConfigurationPaths = .userDefaults) -> Bool {
        let helper = helperURL.path
        guard file(paths.codexHooks, contains: helper),
              file(paths.claudeSettings, contains: helper),
              file(paths.codexConfig, contains: markerBegin) else { return false }
        let dispatcher = paths.codexConfig.deletingLastPathComponent().appendingPathComponent("bin/agent-monitor-notify")
        return file(dispatcher, contains: helper)
    }

    static func install(helperURL: URL, paths: HookConfigurationPaths = .userDefaults) throws {
        try installJSONHooks(at: paths.codexHooks, helperURL: helperURL, subcommand: "codex-hook", addDescription: true)
        try installCodexNotify(at: paths.codexConfig, helperURL: helperURL)
        try installJSONHooks(at: paths.claudeSettings, helperURL: helperURL, subcommand: "claude-hook", addDescription: false)
    }

    static func remove(paths: HookConfigurationPaths = .userDefaults) throws {
        try removeJSONHooks(at: paths.codexHooks, removeDescription: true)
        try removeJSONHooks(at: paths.claudeSettings, removeDescription: false)
        try removeCodexNotify(at: paths.codexConfig)
    }

    private static func installJSONHooks(at url: URL, helperURL: URL, subcommand: String, addDescription: Bool) throws {
        var document = try readJSONObject(at: url)
        var hooks = document["hooks"] as? [String: Any] ?? [:]
        removeMonitorEntries(from: &hooks)
        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            var command: [String: Any] = [
                "type": "command",
                "command": "\(shellQuote(helperURL.path)) \(subcommand)",
                "timeout": 3
            ]
            if event != "SessionEnd" { command["async"] = true }
            entries.append(["matcher": "", "hooks": [command]])
            hooks[event] = entries
        }
        document["hooks"] = hooks
        if addDescription, document["description"] == nil {
            document["description"] = "Report agent session state to Agent Monitor"
        }
        try writeJSON(document, to: url)
    }

    private static func removeJSONHooks(at url: URL, removeDescription: Bool) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var document = try readJSONObject(at: url)
        var hooks = document["hooks"] as? [String: Any] ?? [:]
        removeMonitorEntries(from: &hooks)
        document["hooks"] = hooks
        if removeDescription,
           document["description"] as? String == "Report agent session state to Agent Monitor" {
            document.removeValue(forKey: "description")
        }
        try writeJSON(document, to: url)
    }

    private static func removeMonitorEntries(from hooks: inout [String: Any]) {
        for (event, rawEntries) in hooks {
            guard let entries = rawEntries as? [[String: Any]] else { continue }
            let filtered = entries.filter { entry in
                guard let commands = entry["hooks"] as? [[String: Any]] else { return true }
                return !commands.contains { ($0["command"] as? String)?.contains("agent-monitor-helper") == true }
            }
            if filtered.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = filtered }
        }
    }

    private static func installCodexNotify(at url: URL, helperURL: URL) throws {
        let existing = try readText(at: url)
        var clean = removingManagedBlock(from: existing)
        let codexDirectory = url.deletingLastPathComponent()
        let dispatcher = codexDirectory.appendingPathComponent("bin/agent-monitor-notify")
        let backup = codexDirectory.appendingPathComponent("agent-monitor-original-notify.json")
        var originalNotify = try topLevelNotify(in: clean)

        if originalNotify == [dispatcher.path] {
            originalNotify = nil
        } else if let originalNotify {
            try writeData(JSONEncoder().encode(originalNotify), to: backup, backupExisting: false)
            clean = removingTopLevelNotify(from: clean)
        }
        if originalNotify == nil, let data = try? Data(contentsOf: backup) {
            originalNotify = try? JSONDecoder().decode([String].self, from: data)
        }

        var commands = originalNotify.map { [$0] } ?? []
        commands.append([helperURL.path, "codex-notify"])
        let calls = commands.map { command in
            command.map(shellQuote).joined(separator: " ") + " \"$payload\" || true"
        }
        let dispatcherText = "#!/bin/zsh\npayload=${1:-}\n" + calls.joined(separator: "\n") + "\n"
        try writeText(dispatcherText, to: dispatcher, backupExisting: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dispatcher.path)

        let block = "\(markerBegin)\nnotify = [\"\(dispatcher.path)\"]\n\(markerEnd)\n"
        try writeText(insertingAtTopLevel(block, into: clean), to: url)
    }

    private static func removeCodexNotify(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let codexDirectory = url.deletingLastPathComponent()
        let dispatcher = codexDirectory.appendingPathComponent("bin/agent-monitor-notify")
        let backup = codexDirectory.appendingPathComponent("agent-monitor-original-notify.json")
        var clean = removingManagedBlock(from: try readText(at: url))
        if try topLevelNotify(in: clean) == [dispatcher.path] {
            clean = removingTopLevelNotify(from: clean)
        }
        if let data = try? Data(contentsOf: backup),
           let previous = try? JSONDecoder().decode([String].self, from: data) {
            let encoded = String(data: try JSONEncoder().encode(previous), encoding: .utf8) ?? "[]"
            clean = insertingAtTopLevel("notify = \(encoded)\n", into: clean)
        }
        try writeText(clean, to: url)
        try? FileManager.default.removeItem(at: dispatcher)
        try? FileManager.default.removeItem(at: backup)
    }

    private static func topLevelNotify(in text: String) throws -> [String]? {
        let expression = try NSRegularExpression(pattern: #"(?m)^\s*notify\s*=\s*(\[[^\n]*\])\s*(?:#.*)?$"#)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return try JSONDecoder().decode([String].self, from: Data(text[valueRange].utf8))
    }

    private static func removingTopLevelNotify(from text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"(?m)^\s*notify\s*=\s*\[[^\n]*\]\s*(?:#.*)?\n?"#) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func removingManagedBlock(from text: String) -> String {
        var result: [String] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line == markerBegin { skipping = true; continue }
            if line == markerEnd { skipping = false; continue }
            if !skipping { result.append(line) }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .newlines) + (result.isEmpty ? "" : "\n")
    }

    private static func insertingAtTopLevel(_ block: String, into text: String) -> String {
        guard let range = text.range(of: #"(?m)^\s*\["#, options: .regularExpression) else {
            return text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + block
        }
        return text[..<range.lowerBound] + block + "\n" + text[range.lowerBound...]
    }

    private static func readJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return dictionary
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        try writeData(data, to: url)
    }

    private static func readText(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func writeText(_ text: String, to url: URL, backupExisting: Bool = true) throws {
        try writeData(Data(text.utf8), to: url, backupExisting: backupExisting)
    }

    private static func writeData(_ data: Data, to url: URL, backupExisting: Bool = true) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if backupExisting, manager.fileExists(atPath: url.path) {
            let timestamp = Int(Date().timeIntervalSince1970 * 1_000_000)
            let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).backup-\(timestamp)")
            try? manager.copyItem(at: url, to: backup)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func file(_ url: URL, contains value: String) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8).contains(value)) == true
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
