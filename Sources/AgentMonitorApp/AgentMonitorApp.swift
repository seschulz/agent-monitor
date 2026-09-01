import AppKit
import Combine
import SwiftUI

@main
@MainActor
final class AgentMonitorApp: NSObject, NSApplicationDelegate {
    private let runtime = MonitorRuntime()
    private var menuPanel: StatusMenuPanel?
    private var statusItem: NSStatusItem?
    private var settingsWindowController: NSWindowController?
    private var diagnosticsWindowController: NSWindowController?
    private let diagnosticsWindowState = DiagnosticsWindowState()
    private var completionResetTask: Task<Void, Never>?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    static func main() {
        let application = NSApplication.shared
        let delegate = AgentMonitorApp()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        OverlayDensity.migrateLegacyPreference()
        NSApplication.shared.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenuPanel()
        runtime.store.onCompletion = { [weak self] in
            self?.showCompletionCheck()
        }
        runtime.start()
        offerIntegrationSetupIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        completionResetTask?.cancel()
        removeEventMonitors()
        runtime.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.imagePosition = .imageOnly
        showNormalIcon()
    }

    private func configureMenuPanel() {
        let panel = StatusMenuPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let hostingController = NSHostingController(rootView: MenuContentView(
            store: runtime.store,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onOpenDiagnostics: { [weak self] sessionID in self?.showDiagnostics(sessionID: sessionID) }
        ))
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = hostingController
        menuPanel = panel
        updateMenuPanelSize()

        runtime.store.$sessions
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuPanelSize()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuPanelSize()
            }
            .store(in: &cancellables)
    }

    private func updateMenuPanelSize() {
        guard let menuPanel else { return }
        let densityValue = UserDefaults.standard.string(forKey: "menuBarDensity")
        let density = densityValue.flatMap(MenuBarDensity.init(rawValue:)) ?? .standard
        menuPanel.setContentSize(NSSize(
            width: density.width,
            height: MenuContentView.contentHeight(
                sessionCount: runtime.store.visibleSessions.count,
                density: density
            ) + MenuContentView.arrowHeight
        ))
        if menuPanel.isVisible { positionMenuPanel() }
    }

    @objc private func togglePopover() {
        guard let menuPanel else { return }
        if menuPanel.isVisible {
            hideMenuPanel()
            return
        }
        updateMenuPanelSize()
        positionMenuPanel()
        menuPanel.orderFrontRegardless()
        installEventMonitors()
    }

    private func positionMenuPanel() {
        guard let menuPanel, let anchor = statusButtonScreenFrame() else { return }
        let screenFrame = statusItem?.button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let proposedX = anchor.midX - menuPanel.frame.width / 2
        let x = min(max(proposedX, screenFrame.minX + 6), screenFrame.maxX - menuPanel.frame.width - 6)
        menuPanel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - menuPanel.frame.height + 1))
    }

    private func statusButtonScreenFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func installEventMonitors() {
        guard localEventMonitor == nil, globalEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let menuPanel = self.menuPanel, menuPanel.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.hideMenuPanel()
                return nil
            }
            let location = NSEvent.mouseLocation
            if !menuPanel.frame.contains(location), !(self.statusButtonScreenFrame()?.contains(location) ?? false) {
                self.hideMenuPanel()
            }
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hideMenuPanel() }
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        localEventMonitor = nil
        globalEventMonitor = nil
    }

    private func hideMenuPanel() {
        menuPanel?.orderOut(nil)
        removeEventMonitors()
    }

    private func showCompletionCheck() {
        completionResetTask?.cancel()
        setStatusIcon(named: "checkmark.circle", tint: nil, label: "Agent finished")
        completionResetTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.showNormalIcon()
        }
    }

    private func showNormalIcon() {
        setStatusIcon(named: "bubble.left.and.text.bubble.right", tint: nil, label: "Agent Monitor")
    }

    private func setStatusIcon(named symbolName: String, tint: NSColor?, label: String) {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func showSettings() {
        hideMenuPanel()
        if settingsWindowController == nil {
            let hostingController = NSHostingController(rootView: SettingsView(runtime: runtime))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Agent Monitor Settings"
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 560, height: 520)
            window.setFrameAutosaveName("AgentMonitorSettings")
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func showDiagnostics(sessionID: String?) {
        guard runtime.store.diagnosticsEnabled else { return }
        hideMenuPanel()
        if let sessionID {
            diagnosticsWindowState.selectedSessionID = sessionID
        }
        if diagnosticsWindowController == nil {
            let hostingController = NSHostingController(rootView: DiagnosticTimelineView(
                store: runtime.store,
                state: diagnosticsWindowState
            ))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Agent Monitor Diagnostics"
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 780, height: 500)
            window.setFrameAutosaveName("AgentMonitorDiagnostics")
            window.center()
            diagnosticsWindowController = NSWindowController(window: window)
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        diagnosticsWindowController?.showWindow(nil)
        diagnosticsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func offerIntegrationSetupIfNeeded() {
        guard !runtime.integrationsInstalled,
              !UserDefaults.standard.bool(forKey: "didOfferIntegrationSetup") else { return }
        UserDefaults.standard.set(true, forKey: "didOfferIntegrationSetup")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Finish setting up Agent Monitor"
            alert.informativeText = "Install the Codex and Claude Code integrations so Agent Monitor can receive session updates. Existing hooks are preserved."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Install Integrations")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn, !runtime.installIntegrations() {
                let failure = NSAlert()
                failure.messageText = "Integration setup failed"
                failure.informativeText = runtime.integrationMessage ?? "Open Settings to try again."
                failure.runModal()
            }
        }
    }
}

private final class StatusMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
