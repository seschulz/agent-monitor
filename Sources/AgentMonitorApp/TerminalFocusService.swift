import AppKit
import AgentMonitorShared
import Foundation

enum TerminalFocusService {
    @MainActor
    static func focus(_ host: TerminalHost) async throws {
        // A running application can report as active while all of its windows
        // are minimized. A standard reopen event restores those windows and,
        // by default, reuses the existing application instance.
        try? await reopen(host)

        switch host.kind {
        case .terminalApp:
            try runAppleScript(terminalScript(tty: host.tty))
        case .iTerm2:
            try runAppleScript(iTermScript(tty: host.tty))
        case .intellij, .ghostty, .unknown:
            try await activate(host)
        }
    }

    @MainActor
    private static func reopen(_ host: TerminalHost) async throws {
        let runningApplication = host.hostPid.flatMap(NSRunningApplication.init(processIdentifier:))
        let applicationURL = runningApplication?.bundleURL
            ?? host.bundleIdentifier.flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
        guard let applicationURL else { return }

        runningApplication?.unhide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        try await openApplication(at: applicationURL, configuration: configuration)
    }

    @MainActor
    private static func activate(_ host: TerminalHost) async throws {
        var candidates: [NSRunningApplication] = []
        if let pid = host.hostPid,
           let application = NSRunningApplication(processIdentifier: pid),
           !application.isTerminated,
           host.processStartedAt == nil || application.launchDate.map({ abs($0.timeIntervalSince(host.processStartedAt!)) < 2 }) == true {
            candidates.append(application)
        }
        if let bundleID = host.bundleIdentifier {
            candidates.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: bundleID))
        }

        for application in candidates.uniquedByProcessIdentifier() {
            application.unhide()
            guard application.activate(options: [.activateAllWindows]) else { continue }
            try? await Task.sleep(for: .milliseconds(150))
            if application.isActive { return }
        }

        // Activation can be declined when initiated by a non-activating menu-bar
        // panel. Asking Launch Services to open the existing bundle is a more
        // forceful fallback and does not create a second IntelliJ instance.
        if let bundleID = host.bundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            try await openApplication(at: applicationURL, configuration: configuration)
            return
        }

        throw FocusError.applicationNotRunning
    }

    @MainActor
    private static func openApplication(at url: URL, configuration: NSWorkspace.OpenConfiguration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application != nil {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: FocusError.applicationNotRunning)
                }
            }
        }
    }

    private static func runAppleScript(_ source: String) throws {
        var error: NSDictionary?
        guard NSAppleScript(source: source)?.executeAndReturnError(&error) != nil else {
            throw FocusError.appleScript(error?[NSAppleScript.errorMessage] as? String ?? "Automation failed")
        }
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func terminalScript(tty: String?) -> String {
        guard let tty else { return "tell application \"Terminal\" to activate" }
        return """
        tell application "Terminal"
            activate
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if tty of terminalTab is "\(escaped(tty))" then
                        set selected tab of terminalWindow to terminalTab
                        set index of terminalWindow to 1
                        return
                    end if
                end repeat
            end repeat
            error "Could not locate \(escaped(tty))"
        end tell
        """
    }

    private static func iTermScript(tty: String?) -> String {
        guard let tty else { return "tell application \"iTerm2\" to activate" }
        return """
        tell application "iTerm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        if tty of terminalSession is "\(escaped(tty))" then
                            select terminalTab
                            select terminalWindow
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
            activate
            error "Could not locate \(escaped(tty))"
        end tell
        """
    }

    enum FocusError: LocalizedError {
        case applicationNotRunning
        case appleScript(String)
        var errorDescription: String? {
            switch self {
            case .applicationNotRunning: "The terminal application is not running"
            case let .appleScript(message): message
            }
        }
    }
}

private extension Array where Element == NSRunningApplication {
    func uniquedByProcessIdentifier() -> [NSRunningApplication] {
        var seen = Set<pid_t>()
        return filter { seen.insert($0.processIdentifier).inserted }
    }
}
