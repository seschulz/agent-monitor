import Foundation

enum AppPaths {
    static var baseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentMonitor", isDirectory: true)
    }
    static var helperDirectory: URL { baseDirectory.appendingPathComponent("bin", isDirectory: true) }
    static var helperURL: URL { helperDirectory.appendingPathComponent("agent-monitor-helper") }
    static var socketURL: URL { baseDirectory.appendingPathComponent("events.sock") }
}
