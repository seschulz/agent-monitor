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
              file(paths.claudeSettings, contains: helper) else { return false }
        return hasSafeCodexNotify(helperURL: helperURL, configURL: paths.codexConfig)
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

    static func repairInstalledCodexNotify(helperURL: URL, paths: HookConfigurationPaths = .userDefaults) throws {
        let helper = helperURL.path
        let hasHooks = file(paths.codexHooks, contains: helper) && file(paths.claudeSettings, contains: helper)
        if hasHooks, hasSafeCodexNotify(helperURL: helperURL, configURL: paths.codexConfig) { return }
        try cleanupLegacyCodexNotify(at: paths.codexConfig)
        if hasHooks {
            try installCodexNotify(at: paths.codexConfig, helperURL: helperURL)
        }
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

    private static func cleanupLegacyCodexNotify(at url: URL) throws {
        let codexDirectory = url.deletingLastPathComponent()
        let dispatcher = codexDirectory.appendingPathComponent("bin/agent-monitor-notify")
        let backup = codexDirectory.appendingPathComponent("agent-monitor-original-notify.json")
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            try? manager.removeItem(at: dispatcher)
            try? manager.removeItem(at: backup)
            return
        }

        let existing = try readText(at: url)
        let hadManagedBlock = existing.contains(markerBegin) || existing.contains(markerEnd)
        var clean = removingManagedBlock(from: existing)
        let current = try topLevelNotify(in: clean)
        let cleanedCurrent = current.flatMap { removingDispatcher(from: $0, dispatcherPath: dispatcher.path) }
        let referencesDispatcher = current != cleanedCurrent
        let hasArtifacts = manager.fileExists(atPath: dispatcher.path) || manager.fileExists(atPath: backup.path)
        guard hadManagedBlock || referencesDispatcher || hasArtifacts else { return }

        var desired = cleanedCurrent
        if desired == nil,
           let data = try? Data(contentsOf: backup),
           let previous = try? JSONDecoder().decode([String].self, from: data) {
            desired = removingDispatcher(from: previous, dispatcherPath: dispatcher.path)
        }

        if hadManagedBlock || desired != current {
            clean = removingTopLevelNotify(from: clean)
            if let desired {
                let encoded = try encodeNotify(desired)
                clean = insertingAtTopLevel("notify = \(encoded)\n", into: clean)
            }
            try writeText(clean, to: url)
        }
        try? FileManager.default.removeItem(at: dispatcher)
        try? FileManager.default.removeItem(at: backup)
    }

    private static func installCodexNotify(at url: URL, helperURL: URL) throws {
        try cleanupLegacyCodexNotify(at: url)
        let existing = try readText(at: url)
        var clean = removingManagedBlock(from: existing)
        let codexDirectory = url.deletingLastPathComponent()
        let dispatcher = codexDirectory.appendingPathComponent("bin/agent-monitor-notify")
        let backup = codexDirectory.appendingPathComponent("agent-monitor-original-notify.json")
        var original = try topLevelNotify(in: clean)

        if let original {
            try writeData(try encodedNotifyData(original), to: backup, backupExisting: false)
            clean = removingTopLevelNotify(from: clean)
        } else if let data = try? Data(contentsOf: backup) {
            original = try? JSONDecoder().decode([String].self, from: data)
        }

        let helperCommand = [helperURL.path, "codex-notify"]
        let installedCommand: [String]
        if var original, isCodexComputerUse(original) {
            if let previousIndex = original.firstIndex(of: "--previous-notify"), previousIndex + 1 < original.count,
               let previousData = original[previousIndex + 1].data(using: .utf8),
               let previous = try? JSONDecoder().decode([String].self, from: previousData) {
                try writeDispatcher(at: dispatcher, commands: [previous, helperCommand])
                original[previousIndex + 1] = try encodeNotify([dispatcher.path])
            } else {
                original.append(contentsOf: ["--previous-notify", try encodeNotify(helperCommand)])
            }
            installedCommand = original
        } else if let original {
            try writeDispatcher(at: dispatcher, commands: [original, helperCommand])
            installedCommand = [dispatcher.path]
        } else {
            installedCommand = helperCommand
        }

        let block = "\(markerBegin)\nnotify = \(try encodeNotify(installedCommand))\n\(markerEnd)\n"
        try writeText(insertingAtTopLevel(block, into: clean), to: url)
    }

    private static func removeCodexNotify(at url: URL) throws {
        try cleanupLegacyCodexNotify(at: url)
    }

    private static func isCodexComputerUse(_ command: [String]) -> Bool {
        command.first.map { URL(fileURLWithPath: $0).lastPathComponent == "SkyComputerUseClient" } == true
            && command.dropFirst().first == "turn-ended"
    }

    private static func hasSafeCodexNotify(helperURL: URL, configURL: URL) -> Bool {
        if file(configURL, contains: helperURL.path) { return true }
        let dispatcher = configURL.deletingLastPathComponent().appendingPathComponent("bin/agent-monitor-notify")
        guard file(configURL, contains: dispatcher.path),
              let script = try? String(contentsOf: dispatcher, encoding: .utf8) else { return false }
        return script.contains(helperURL.path) && !script.contains("SkyComputerUseClient")
    }

    private static func writeDispatcher(at url: URL, commands: [[String]]) throws {
        let calls = commands.map { command in
            command.map(shellQuote).joined(separator: " ") + " \"$payload\" || true"
        }
        let text = "#!/bin/zsh\npayload=${1:-}\n" + calls.joined(separator: "\n") + "\n"
        try writeText(text, to: url, backupExisting: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func removingDispatcher(from command: [String], dispatcherPath: String) -> [String]? {
        guard command.first != dispatcherPath else { return nil }
        var result = command
        var index = 0
        while index + 1 < result.count {
            guard result[index] == "--previous-notify",
                  let data = result[index + 1].data(using: .utf8),
                  let previous = try? JSONDecoder().decode([String].self, from: data) else {
                index += 1
                continue
            }
            if let cleaned = removingDispatcher(from: previous, dispatcherPath: dispatcherPath) {
                if cleaned != previous,
                   let encoded = try? encodeNotify(cleaned) {
                    result[index + 1] = encoded
                }
                index += 2
            } else {
                result.removeSubrange(index ... index + 1)
            }
        }
        return result
    }

    private static func encodeNotify(_ command: [String]) throws -> String {
        String(data: try encodedNotifyData(command), encoding: .utf8) ?? "[]"
    }

    private static func encodedNotifyData(_ command: [String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(command)
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
