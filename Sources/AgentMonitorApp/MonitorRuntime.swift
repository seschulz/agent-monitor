import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class MonitorRuntime: ObservableObject {
    let store = SessionStore()
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var integrationsInstalled = false
    @Published private(set) var integrationMessage: String?
    private var server: SocketServer?
    private var timer: Timer?
    private var overlay: OverlayController?

    func start() {
        guard server == nil else { return }
        UserDefaults.standard.register(defaults: [
            "overlayEnabled": true,
            "showReadyInOverlay": true,
            "overlayRetentionMinutes": 5,
            "overlayDensity": OverlayDensity.standard.rawValue,
            "menuBarDensity": MenuBarDensity.standard.rawValue,
            "showTerminalInMenuBar": true,
            "readyRetentionMinutes": 15,
            "speechEnabled": false,
            "speakOnCompletion": true,
            "speechVoice": SpeechService.systemDefaultVoice
        ])
        store.reconcileProcesses()
        refreshLaunchAtLoginStatus()
        do {
            try HookConfigurationService.repairInstalledCodexNotify(helperURL: helperURL)
        } catch {
            store.showMessage("Could not repair the legacy Codex integration: \(error.localizedDescription)")
        }
        refreshIntegrationStatus()
        let server = SocketServer { [weak self] event in
            Task { @MainActor in
                self?.store.apply(event)
                self?.refreshOverlay()
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            store.showMessage(error.localizedDescription)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.store.reconcileProcesses()
                self?.refreshOverlay()
            }
        }
        refreshOverlay()
    }

    func stop() {
        timer?.invalidate()
        server?.stop()
        overlay?.close()
    }

    func refreshOverlay() {
        store.refreshDisplay()
        guard UserDefaults.standard.bool(forKey: "overlayEnabled") else {
            overlay?.close()
            overlay = nil
            return
        }
        if overlay == nil {
            overlay = OverlayController(store: store) { [weak self] in
                self?.refreshOverlay()
            }
        }
        overlay?.updateVisibility(hasSessions: !store.overlaySessions.isEmpty)
    }

    func requestNotifications(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "notificationsEnabled")
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted { UserDefaults.standard.set(false, forKey: "notificationsEnabled") }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            store.showMessage("Could not update Launch at Login: \(error.localizedDescription)")
        }
        refreshLaunchAtLoginStatus()
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agent-monitor-helper")
    }

    func installIntegrations() -> Bool {
        do {
            try HookConfigurationService.install(helperURL: helperURL)
            integrationsInstalled = true
            integrationMessage = "Codex and Claude Code integrations are installed."
            return true
        } catch {
            integrationMessage = "Could not install integrations: \(error.localizedDescription)"
            return false
        }
    }

    func removeIntegrations() {
        do {
            try HookConfigurationService.remove()
            integrationsInstalled = false
            integrationMessage = "Agent integrations were removed."
        } catch {
            integrationMessage = "Could not remove integrations: \(error.localizedDescription)"
        }
    }

    func refreshIntegrationStatus() {
        integrationsInstalled = HookConfigurationService.isInstalled(helperURL: helperURL)
    }

    private func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled || status == .requiresApproval
        launchAtLoginNeedsApproval = status == .requiresApproval
    }
}
