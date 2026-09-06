import AppKit
import ApplicationServices
import AgentMonitorShared
import Darwin

/// Sends only title-control sequences to the verified PTY's output. Never
/// injects shell input, reads terminal content, or writes to the /dev/tty alias.
@MainActor
private final class TerminalTitleProbe {
    let marker = JetBrainsTerminalFocus.makeTitleMarker()
    private let descriptor: Int32
    private var saved = false

    init?(shell: TerminalShellIdentity, hostPID: Int32) {
        guard shell.isLive(inHost: hostPID), TerminalShellIdentity.isConcreteTTY(shell.tty) else { return nil }
        let fd = Darwin.open(shell.tty, O_WRONLY | O_NOCTTY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), isatty(fd) == 1,
              shell.isLive(inHost: hostPID) else { Darwin.close(fd); return nil }
        descriptor = fd
    }

    func start() -> Bool {
        saved = write("\u{1B}[22;2t")
        return saved
    }

    func mark() -> Bool { write("\u{1B}]2;\(marker)\u{07}") }

    func restoreTitle(_ title: String) {
        let safe = String(String.UnicodeScalarView(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).prefix(256)
        _ = write("\u{1B}]2;\(safe)\u{07}")
    }

    func restore() {
        if saved {
            _ = write("\u{1B}[23;2t")
            saved = false
        }
    }

    func close() {
        restore()
        Darwin.close(descriptor)
    }

    private func write(_ sequence: String) -> Bool {
        let bytes = Array(sequence.utf8)
        return bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}

/// A remembered association, matched only when the tab name is unique.
struct JetBrainsTabLink: Codable, Equatable {
    let windowKey: String
    let tabName: String
    let hostPID: Int32
    let hostStartedAt: Date
    let savedAt: Date

    func belongsTo(pid: Int32, startedAt: Date) -> Bool {
        hostPID == pid && abs(hostStartedAt.timeIntervalSince(startedAt)) < 2
    }

    static func uniqueMatch(windowKey: String, tabName: String, in tabs: [JetBrainsTabIdentity]) -> Int? {
        let matches = tabs.indices.filter { tabs[$0].windowKey == windowKey && tabs[$0].tabName == tabName }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct JetBrainsTabIdentity: Equatable {
    let windowKey: String
    let tabName: String
}

@MainActor
enum JetBrainsTerminalFocus {
    // Retain the original keys to preserve existing settings and associations.
    private static let defaultsKey = "intellijTerminalTabLinks"
    private static var focusInProgress = false

    static func makeTitleMarker() -> String {
        // IntelliJ TerminalTitle.shortenApplicationTitle trims to 30 chars.
        // Keep the entire nonce visible instead of matching truncated titles.
        "AM-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
    }

    private struct Tab {
        let identity: JetBrainsTabIdentity
        let window: AXUIElement
        let header: AXUIElement
        let element: AXUIElement
    }

    static func focus(_ session: SessionRecord) async throws {
        // Keep rapid double-clicks from racing title probes and focus.
        guard !focusInProgress else { return }
        focusInProgress = true
        defer { focusInProgress = false }

        // Opening the host does not require Accessibility. Permission is
        // requested only through Settings, never while clicking a session.
        guard UserDefaults.standard.bool(forKey: "intellijTabSwitchingEnabled"),
              AXIsProcessTrusted() else { return }

        let host = session.terminal
        guard let pid = host.hostPid,
              let application = NSRunningApplication(processIdentifier: pid),
              !application.isTerminated,
              let startedAt = application.launchDate ?? ProcessIdentity.startedAt(pid: pid),
              host.processStartedAt.map({ abs($0.timeIntervalSince(startedAt)) < 2 }) ?? true else {
            throw Failure("The original IDE instance is no longer running. Start a new agent session to focus its terminal.")
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var links = loadLinks()
        let shell = host.shell.flatMap { $0.isLive(inHost: pid) ? $0 : nil }
        if host.shell != nil && shell == nil {
            throw Failure("The terminal shell for this session has closed. Open a new agent session to focus its terminal.")
        }
        let reusable = shell.flatMap { links[$0.key] }
        let saved = (reusable ?? links[session.id]).flatMap { $0.belongsTo(pid: pid, startedAt: startedAt) ? $0 : nil }
        var tabs = collectTabs(app)

        // A hidden tool window is absent from the accessibility tree. Reveal it
        // only in the linked project window, never by sending a terminal key.
        if let saved,
           !tabs.contains(where: { $0.identity.windowKey == saved.windowKey }) {
            try await revealTerminal(app, windowKey: saved.windowKey, application: application)
            tabs = collectTabs(app)
        }

        if let shell {
            // New tabs have no saved link. Reveal the project's Terminal tool
            // window when its path uniquely contains the working directory.
            let windows = elements(app, kAXWindowsAttribute)
            let keys = windows.map { windowKey($0, nodes: structuralDescendants($0)) }
                .filter { Self.containsWorkingDirectory(windowKey: $0, cwd: session.cwd) }
            if keys.count == 1, !tabs.contains(where: { $0.identity.windowKey == keys[0] }) {
                try await revealTerminal(app, windowKey: keys[0], application: application)
            }
            if let automaticTab = try await locateAutomatically(shell: shell, hostPID: pid, app: app) {
                try await select(automaticTab, host: host, application: application)
                saveLink(automaticTab.identity, sessionID: session.id, shell: shell, pid: pid, startedAt: startedAt, links: &links)
                return
            }
            tabs = collectTabs(app)
        }

        // The IDE is already in front. If automatic identification failed,
        // use a remembered unique tab when available; otherwise leave it there
        // without asking the user to link or rename terminals.
        guard let saved,
              let index = JetBrainsTabLink.uniqueMatch(windowKey: saved.windowKey, tabName: saved.tabName, in: tabs.map(\.identity)) else { return }
        let tab = tabs[index]
        try await select(tab, host: host, application: application)
        saveLink(tab.identity, sessionID: session.id, shell: shell, pid: pid, startedAt: startedAt, links: &links)
    }

    private static func saveLink(_ target: JetBrainsTabIdentity, sessionID: String, shell: TerminalShellIdentity?, pid: Int32,
                                 startedAt: Date, links: inout [String: JetBrainsTabLink]) {
        let link = JetBrainsTabLink(windowKey: target.windowKey, tabName: target.tabName,
                                  hostPID: pid, hostStartedAt: startedAt, savedAt: Date())
        links[sessionID] = link
        if let shell { links[shell.key] = link }
        if let data = try? JSONEncoder().encode(links) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    private static func select(_ tab: Tab, host: TerminalHost, application: NSRunningApplication) async throws {
        try await TerminalFocusService.activate(host)
        AXUIElementSetAttributeValue(tab.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(tab.window, kAXRaiseAction as CFString)
        try await Task.sleep(for: .milliseconds(150))
        guard application.isActive else { throw Failure("Bring the IDE to the foreground and try again.") }
        try press(tab.element)

        // JetBrains exposes the selected terminal name as "<name> Tool Window".
        // Confirm that it actually changed, rather than assuming a click worked.
        var selected = false
        for _ in 0..<5 {
            if string(tab.header, kAXDescriptionAttribute) == "\(tab.identity.tabName) Tool Window"
                || (attribute(tab.element, kAXSelectedAttribute) as? Bool) == true {
                selected = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard selected else {
            throw Failure("The IDE did not confirm the terminal tab selection. Keep its Terminal tool window visible and try again.")
        }
    }

    static func containsWorkingDirectory(windowKey: String, cwd: String) -> Bool {
        guard windowKey.hasPrefix("/") || windowKey.hasPrefix("~/") else { return false }
        let project = URL(fileURLWithPath: (windowKey as NSString).expandingTildeInPath).standardized.path
        let directory = URL(fileURLWithPath: cwd).standardized.path
        return directory == project || directory.hasPrefix(project + "/")
    }

    private static func locateAutomatically(shell: TerminalShellIdentity, hostPID: Int32, app: AXUIElement) async throws -> Tab? {
        func diagnose(_ message: String) { UserDefaults.standard.set(message, forKey: "intellijLastAutomaticFocusResult") }
        guard let probe = TerminalTitleProbe(shell: shell, hostPID: hostPID) else {
            diagnose("Terminal device unavailable")
            return nil
        }
        defer { probe.close() }
        let before = collectTabs(app)
        guard probe.start() else { diagnose("Could not save terminal title"); return nil }
        var observedCount = 0
        // The reworked terminal publishes its title asynchronously. Allow its
        // frontend to flush updates before treating the tab as unsupported.
        for _ in 0..<12 {
            guard probe.mark() else { diagnose("Could not write terminal title"); return nil }
            try await Task.sleep(for: .milliseconds(250))
            let observed = collectTabs(app)
            observedCount = observed.count
            let matches = observed.filter { tab in
                [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains {
                    string(tab.element, $0)?.contains(probe.marker) == true
                }
            }
            guard matches.count == 1, let marked = matches.first else { continue }
            let original = before.first { CFEqual($0.element, marked.element) && CFEqual($0.window, marked.window) }
            // Keep the exact AX element identified by the nonce. Restoring the
            // original label must not make us fall back to a duplicate name.
            probe.restore()
            for attempt in 0..<10 {
                try await Task.sleep(for: .milliseconds(150))
                if let name = label(marked.element), !name.isEmpty, !name.contains(probe.marker) {
                    diagnose("Identified terminal and restored title")
                    return Tab(identity: .init(windowKey: marked.identity.windowKey, tabName: name), window: marked.window,
                               header: marked.header, element: marked.element)
                }
                // Some engines accept OSC titles but do not implement the
                // title stack. Restore the same element's pre-probe title.
                if attempt == 2, let original { probe.restoreTitle(original.identity.tabName) }
            }
            diagnose("Identified terminal but title restoration was not confirmed; original element: \(original != nil)")
            return nil
        }
        diagnose("Title marker not exposed among \(observedCount) terminal tabs")
        return nil
    }

    private static func loadLinks() -> [String: JetBrainsTabLink] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let links = try? JSONDecoder().decode([String: JetBrainsTabLink].self, from: data) else { return [:] }
        return links.filter { Date().timeIntervalSince($0.value.savedAt) < 30 * 24 * 60 * 60 }
    }

    private static func collectTabs(_ app: AXUIElement) -> [Tab] {
        var result: [Tab] = []
        for window in elements(app, kAXWindowsAttribute) {
            let nodes = structuralDescendants(window)
            let key = windowKey(window, nodes: nodes)
            for node in nodes {
                let children = elements(node, kAXChildrenAttribute)
                // IntelliJ and Rider present the terminal header as direct static-text
                // siblings: "Terminal", then its tab labels, then toolbars.
                guard string(node, kAXDescriptionAttribute)?.hasSuffix(" Tool Window") == true,
                      let heading = children.first,
                      string(heading, kAXRoleAttribute) == kAXStaticTextRole,
                      label(heading) == "Terminal" else { continue }
                for child in children.dropFirst() {
                    guard string(child, kAXRoleAttribute) == kAXStaticTextRole else { break }
                    guard let name = label(child), !name.isEmpty else { continue }
                    result.append(Tab(identity: .init(windowKey: key, tabName: name), window: window, header: node, element: child))
                }
            }
        }
        return result
    }

    private static func revealTerminal(_ app: AXUIElement, windowKey target: String, application: NSRunningApplication) async throws {
        let matching = elements(app, kAXWindowsAttribute).filter { windowKey($0, nodes: structuralDescendants($0)) == target }
        guard matching.count == 1, let window = matching.first else { return }
        let buttons = structuralDescendants(window).filter {
            string($0, kAXRoleAttribute) == kAXButtonRole && label($0) == "Terminal"
        }
        guard buttons.count == 1, let button = buttons.first else { return }
        application.activate(options: [])
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        try await Task.sleep(for: .milliseconds(150))
        guard application.isActive else { return }
        try press(button)
        try await Task.sleep(for: .milliseconds(250))
    }

    private static func windowKey(_ window: AXUIElement, nodes: [AXUIElement]) -> String {
        for node in nodes where string(node, kAXRoleAttribute) == kAXButtonRole {
            if string(node, kAXDescriptionAttribute)?.hasPrefix("Project:") == true,
               let path = string(node, kAXHelpAttribute), !path.isEmpty { return path }
        }
        return (string(window, kAXTitleAttribute) ?? "JetBrains IDE").components(separatedBy: " – ").first ?? "JetBrains IDE"
    }

    /// Never retrieve editor/terminal values or walk project trees/scrollback.
    private static func structuralDescendants(_ root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        let deadline = Date().addingTimeInterval(2)
        while let (element, depth) = pending.popLast(), result.count < 1200, Date() < deadline {
            let role = string(element, kAXRoleAttribute) ?? ""
            if [kAXTextAreaRole, kAXTextFieldRole, kAXScrollAreaRole, kAXOutlineRole, kAXTableRole].contains(role) { continue }
            result.append(element)
            if depth < 18 {
                pending.append(contentsOf: elements(element, kAXChildrenAttribute).reversed().map { ($0, depth + 1) })
            }
        }
        return result
    }

    private static func press(_ element: AXUIElement) throws {
        // JetBrains static-text tab labels can report a successful AXPress
        // without selecting anything. Only use AXPress for actual controls.
        if string(element, kAXRoleAttribute) != kAXStaticTextRole,
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success { return }
        // JetBrains tab labels expose live bounds. Use those
        // live bounds, never a stored tab index or a hard-coded coordinate.
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw Failure("The IDE did not expose a selectable terminal tab.")
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions), dimensions.width > 0, dimensions.height > 0 else {
            throw Failure("The terminal tab is not visible.")
        }
        point.x += dimensions.width / 2
        point.y += dimensions.height / 2
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw Failure("Could not select the terminal tab.")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
    private static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] { attribute(element, name) as? [AXUIElement] ?? [] }
    private static func label(_ element: AXUIElement) -> String? {
        let attributes = string(element, kAXRoleAttribute) == kAXStaticTextRole
            ? [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
            : [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
        return attributes
            .compactMap { string(element, $0) }
            .first { !$0.isEmpty }
    }

    static func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not select the IDE terminal"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
