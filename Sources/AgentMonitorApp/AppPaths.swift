import Foundation

enum AppPaths {
    static var baseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentMonitor", isDirectory: true)
    }
    static var socketURL: URL { baseDirectory.appendingPathComponent("events.sock") }
}
