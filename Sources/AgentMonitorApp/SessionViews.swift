import AppKit
import AgentMonitorShared
import SwiftUI

enum OverlayDensity: String, CaseIterable, Identifiable {
    case minimal
    case compact
    case standard
    case spacious

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var width: CGFloat {
        switch self {
        case .minimal: 235
        case .compact: 250
        case .standard: 280
        case .spacious: 340
        }
    }

    var rowPadding: CGFloat {
        switch self {
        case .minimal: 2
        case .compact: 5
        case .standard: 8
        case .spacious: 12
        }
    }

    var containerPadding: CGFloat {
        switch self {
        case .minimal: 2
        case .compact: 4
        case .standard: 6
        case .spacious: 10
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .minimal: 0
        case .compact: 0
        case .standard: 2
        case .spacious: 5
        }
    }

    var titleSize: CGFloat {
        switch self {
        case .minimal: 10
        case .compact: 12
        case .standard: 13
        case .spacious: 15
        }
    }

    var detailSize: CGFloat {
        switch self {
        case .minimal: 9
        case .compact: 10
        case .standard: 11
        case .spacious: 12
        }
    }

    static var current: OverlayDensity {
        guard let value = UserDefaults.standard.string(forKey: "overlayDensity") else { return .standard }
        return OverlayDensity(rawValue: value) ?? .standard
    }
}

enum MenuBarDensity: String, CaseIterable, Identifiable {
    case compact
    case standard
    case spacious

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var width: CGFloat {
        switch self {
        case .compact: 320
        case .standard: 360
        case .spacious: 420
        }
    }

    var rowPadding: CGFloat {
        switch self {
        case .compact: 7
        case .standard: 10
        case .spacious: 14
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: 44
        case .standard: 54
        case .spacious: 66
        }
    }

    var titleSize: CGFloat {
        switch self {
        case .compact: 12
        case .standard: 13
        case .spacious: 15
        }
    }

    var detailSize: CGFloat {
        switch self {
        case .compact: 10
        case .standard: 11
        case .spacious: 12
        }
    }
}

struct MenuContentView: View {
    static let arrowHeight: CGFloat = 10
    nonisolated static let headerHeight: CGFloat = 34

    @ObservedObject var store: SessionStore
    let onOpenSettings: () -> Void
    @AppStorage("menuBarDensity") private var densityRawValue = MenuBarDensity.standard.rawValue
    @AppStorage("showTerminalInMenuBar") private var showTerminalDetails = true

    private var density: MenuBarDensity {
        MenuBarDensity(rawValue: densityRawValue) ?? .standard
    }

    private var contentHeight: CGFloat {
        Self.contentHeight(sessionCount: store.visibleSessions.count, density: density)
    }

    nonisolated static func contentHeight(sessionCount: Int, density: MenuBarDensity) -> CGFloat {
        let listHeight = sessionCount == 0
            ? 150
            : CGFloat(sessionCount) * density.rowHeight + CGFloat(max(sessionCount - 1, 0))
        return Self.headerHeight + 1 + listHeight + 1 + 42
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                Text("Agent Monitor")
                    .fontWeight(.semibold)
                Spacer()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: Self.headerHeight)
            Divider().frame(height: 1)

            if store.visibleSessions.isEmpty {
                VStack(spacing: 7) {
                    Text("No agent sessions")
                        .font(.body.weight(.semibold))
                    Text("Start Codex or Claude Code in any terminal after installing the hooks.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: density.width - 60)
                }
                    .frame(width: density.width - 30, height: 150)
            } else {
                ForEach(store.visibleSessions) { session in
                    HStack(spacing: 0) {
                        SessionRow(
                            session: session,
                            compact: false,
                            menuBarDensity: density,
                            showTerminalDetails: showTerminalDetails
                        ) { focus(session) }
                        .contextMenu {
                            Button("Open terminal") { focus(session) }
                            Button("Copy working directory") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(session.cwd, forType: .string)
                            }
                            Divider()
                            Button("Dismiss") { store.dismiss(session.id) }
                        }
                        if session.status == .ready {
                            Button {
                                store.dismiss(session.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Dismiss \(session.displayName)")
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, density.rowPadding)
                            .help("Dismiss session")
                        }
                    }
                    if session.id != store.visibleSessions.last?.id { Divider().frame(height: 1) }
                }
            }
            Divider().frame(height: 1)
            HStack {
                Button {
                    onOpenSettings()
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 42)
        }
        .frame(width: density.width, height: contentHeight)
        .padding(.top, Self.arrowHeight)
        .background {
            MenuVisualEffect()
                .overlay(.black.opacity(0.14))
                .clipShape(MenuPanelShape(arrowHeight: Self.arrowHeight, cornerRadius: 12))
        }
        .clipShape(MenuPanelShape(arrowHeight: Self.arrowHeight, cornerRadius: 12))
        .overlay {
            MenuPanelShape(arrowHeight: Self.arrowHeight, cornerRadius: 12)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if let message = store.lastMessage {
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 336, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.35)))
                    .shadow(radius: 5, y: 2)
                    .padding(.bottom, 46)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: store.lastMessage)
    }

    private func focus(_ session: SessionRecord) {
        Task {
            do { try await TerminalFocusService.focus(session.terminal) }
            catch {
                if let bundleID = session.terminal.bundleIdentifier,
                   let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    app.activate(options: [.activateAllWindows])
                    store.showMessage("Could not locate \(session.terminal.tty ?? "the terminal tab"); opened \(session.terminal.displayName) instead.")
                } else {
                    store.showMessage(error.localizedDescription)
                }
            }
        }
    }

}

private struct MenuVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct MenuPanelShape: Shape {
    let arrowHeight: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + arrowHeight, width: rect.width, height: rect.height - arrowHeight)
        let radius = min(cornerRadius, body.width / 2, body.height / 2)
        let arrowHalfWidth: CGFloat = 12
        let centerX = rect.midX
        var path = Path()

        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: centerX - arrowHalfWidth, y: body.minY))
        path.addLine(to: CGPoint(x: centerX, y: rect.minY))
        path.addLine(to: CGPoint(x: centerX + arrowHalfWidth, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY + radius), control: CGPoint(x: body.maxX, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: body.maxX - radius, y: body.maxY), control: CGPoint(x: body.maxX, y: body.maxY))
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addQuadCurve(to: CGPoint(x: body.minX, y: body.maxY - radius), control: CGPoint(x: body.minX, y: body.maxY))
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addQuadCurve(to: CGPoint(x: body.minX + radius, y: body.minY), control: CGPoint(x: body.minX, y: body.minY))
        path.closeSubpath()
        return path
    }
}

struct SessionRow: View {
    let session: SessionRecord
    let compact: Bool
    var menuBarDensity: MenuBarDensity = .standard
    var showTerminalDetails = true
    let action: () -> Void
    @AppStorage("overlayDensity") private var densityRawValue = OverlayDensity.standard.rawValue

    private var overlayDensity: OverlayDensity {
        OverlayDensity(rawValue: densityRawValue) ?? .standard
    }

    var body: some View {
        Button(action: action) {
            rowContent
            .contentShape(Rectangle())
            .padding(compact ? overlayDensity.rowPadding : menuBarDensity.rowPadding)
        }
        .buttonStyle(.plain)
        .help("\(session.displayName)\n\(session.status.label) · \(session.provider.displayName) · \(session.terminal.displayName)\n\(session.cwd)")
        .frame(height: compact ? nil : menuBarDensity.rowHeight)
    }

    @ViewBuilder
    private var rowContent: some View {
        if compact && overlayDensity == .minimal {
            HStack(spacing: 3) {
                Image(systemName: session.status.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.pulse, options: .repeating, isActive: session.status == .running)
                    .foregroundStyle(session.status.color)
                    .frame(width: 14)
                    .accessibilityLabel(session.status.accessibilityLabel)
                Text(session.displayName)
                    .font(.system(size: overlayDensity.titleSize, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                Text(session.provider.displayName)
                    .font(.system(size: overlayDensity.detailSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 34, alignment: .leading)
                Text(session.terminal.displayName)
                    .font(.system(size: overlayDensity.detailSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 34, alignment: .leading)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.minimalTime(for: session, at: context.date))
                        .font(.system(size: overlayDensity.detailSize, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                }
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: session.status.symbol)
                    .symbolEffect(.pulse, options: .repeating, isActive: session.status == .running)
                    .foregroundStyle(session.status.color)
                    .frame(width: 20)
                    .accessibilityLabel(session.status.accessibilityLabel)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.displayName)
                            .font(.system(size: compact ? overlayDensity.titleSize : menuBarDensity.titleSize, weight: .medium))
                            .lineLimit(1)
                        if compact {
                            Spacer(minLength: 8)
                            Text("\(session.provider.displayName) · \(session.terminal.displayName)")
                                .font(.system(size: overlayDensity.detailSize))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.12), in: Capsule())
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    if compact {
                        sessionDetails(includeTerminal: false)
                    } else {
                        sessionDetails(includeTerminal: showTerminalDetails)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func sessionDetails(includeTerminal: Bool) -> some View {
        HStack(spacing: 4) {
            Text(session.status.label)
            if includeTerminal {
                Text("·")
                Text(session.provider.displayName)
                Text("·")
                Text(session.terminal.displayName)
            }
            Text("·")
            if session.status == .running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsedTime(from: session.startedAt, to: context.date))
                        .monospacedDigit()
                }
            } else {
                Text(session.updatedAt, style: .relative)
            }
        }
        .font(.system(size: compact ? overlayDensity.detailSize : menuBarDensity.detailSize))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    nonisolated static func elapsedTime(from startDate: Date, to endDate: Date) -> String {
        let elapsed = max(0, Int(endDate.timeIntervalSince(startDate)))
        let hours = elapsed / 3_600
        let minutes = (elapsed % 3_600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    nonisolated static func minimalTime(for session: SessionRecord, at date: Date) -> String {
        if session.status == .running {
            return elapsedTime(from: session.startedAt, to: date)
        }
        let seconds = max(0, Int(date.timeIntervalSince(session.updatedAt)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }
}

struct SettingsView: View {
    @ObservedObject var runtime: MonitorRuntime
    @AppStorage("overlayEnabled") private var overlayEnabled = true
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("readyRetentionMinutes") private var readyRetentionMinutes = 15
    @AppStorage("showReadyInOverlay") private var showReadyInOverlay = true
    @AppStorage("overlayRetentionMinutes") private var overlayRetentionMinutes = 5
    @AppStorage("speechEnabled") private var speechEnabled = false
    @AppStorage("speakOnCompletion") private var speakOnCompletion = true
    @AppStorage("speechVoice") private var speechVoice = SpeechService.systemDefaultVoice
    @AppStorage("overlayDensity") private var overlayDensity = OverlayDensity.standard.rawValue
    @AppStorage("menuBarDensity") private var menuBarDensity = MenuBarDensity.standard.rawValue
    @AppStorage("showTerminalInMenuBar") private var showTerminalInMenuBar = true

    var body: some View {
        Form {
            Section("Application") {
                Toggle("Launch at login", isOn: Binding(
                    get: { runtime.launchAtLoginEnabled },
                    set: { runtime.setLaunchAtLogin($0) }
                ))
                if runtime.launchAtLoginNeedsApproval {
                    HStack {
                        Text("macOS needs your approval before Agent Monitor can launch automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { runtime.openLoginItemSettings() }
                    }
                }
                HStack {
                    LabeledContent(
                        "Codex and Claude Code",
                        value: runtime.integrationsInstalled ? "Installed" : "Not installed"
                    )
                    Spacer()
                    if runtime.integrationsInstalled {
                        Button("Remove Integrations") { runtime.removeIntegrations() }
                    } else {
                        Button("Install Integrations") { _ = runtime.installIntegrations() }
                    }
                }
                if let message = runtime.integrationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Menu Bar") {
                Text("Controls the session list shown when you click the Agent Monitor icon in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Row density", selection: $menuBarDensity) {
                    ForEach(MenuBarDensity.allCases) { density in
                        Text(density.label).tag(density.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Show provider and terminal", isOn: $showTerminalInMenuBar)
                Stepper("Keep completed sessions for \(readyRetentionMinutes) minutes", value: $readyRetentionMinutes, in: 1...120)
            }

            Section("Floating Overlay") {
                Toggle("Show floating overlay", isOn: $overlayEnabled)
                    .onChange(of: overlayEnabled) { _, _ in runtime.refreshOverlay() }
                Picker("Widget density", selection: $overlayDensity) {
                    ForEach(OverlayDensity.allCases) { density in
                        Text(density.label).tag(density.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!overlayEnabled)
                .onChange(of: overlayDensity) { _, _ in runtime.refreshOverlay() }
                Toggle("Show completed sessions", isOn: $showReadyInOverlay)
                    .disabled(!overlayEnabled)
                    .onChange(of: showReadyInOverlay) { _, _ in runtime.refreshOverlay() }
                Stepper(
                    "Hide completed sessions after \(overlayRetentionMinutes) minutes",
                    value: $overlayRetentionMinutes,
                    in: 1...120
                )
                .disabled(!overlayEnabled)
                .onChange(of: overlayRetentionMinutes) { _, _ in runtime.refreshOverlay() }
            }

            Section("Alerts") {
                Toggle("Show macOS notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, value in runtime.requestNotifications(value) }
                Toggle("Speak session status", isOn: $speechEnabled)
                Toggle("When a session finishes", isOn: $speakOnCompletion)
                    .disabled(!speechEnabled)
                Text("Claude is announced only when its Stop event reports that the turn finished.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Voice", selection: $speechVoice) {
                    ForEach(SpeechService.availableVoices, id: \.self) { voice in
                        Text(voice).tag(voice)
                    }
                }
                .disabled(!speechEnabled)
                Button("Test Voice") {
                    SpeechService.speak("Agent finished", voice: speechVoice)
                }
                .disabled(!speechEnabled)
            }

            Section("Data") {
                LabeledContent("Event socket", value: AppPaths.socketURL.path)
                    .textSelection(.enabled)
                HStack {
                    Button("Clear session history") { runtime.store.clearAll() }
                    Spacer()
                    Button("Open data folder") { NSWorkspace.shared.open(AppPaths.baseDirectory) }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 600, height: runtime.launchAtLoginNeedsApproval ? 720 : 680)
    }
}

private extension SessionStatus {
    var label: String {
        switch self {
        case .running: "Running"
        case .attention: "Needs attention"
        case .ready: "Ready"
        case .stale: "Disconnected"
        case .closed: "Closed"
        }
    }
    var accessibilityLabel: String { label }
    var symbol: String {
        switch self {
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .attention: "exclamationmark.triangle.fill"
        case .ready: "checkmark.circle.fill"
        case .stale: "cable.connector.slash"
        case .closed: "xmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .running: .blue
        case .attention: .orange
        case .ready: .green
        case .stale, .closed: .secondary
        }
    }
}

private extension TerminalHost {
    @MainActor
    var displayName: String {
        switch kind {
        case .terminalApp: "Terminal"
        case .iTerm2: "iTerm2"
        case .ghostty: "Ghostty"
        case .intellij: "IntelliJ"
        case .unknown:
            ApplicationNameResolver.name(hostPID: hostPid, bundleIdentifier: bundleIdentifier)
                ?? bundleIdentifier
                ?? "Unknown terminal"
        }
    }
}

@MainActor
private enum ApplicationNameResolver {
    private static var cachedBundleNames: [String: String] = [:]

    static func name(hostPID: Int32?, bundleIdentifier: String?) -> String? {
        if let hostPID,
           let runningName = cleaned(NSRunningApplication(processIdentifier: hostPID)?.localizedName) {
            return runningName
        }

        guard let bundleIdentifier else { return nil }
        if let cached = cachedBundleNames[bundleIdentifier] { return cached }

        if let runningName = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .lazy
            .compactMap({ cleaned($0.localizedName) })
            .first {
            cachedBundleNames[bundleIdentifier] = runningName
            return runningName
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let bundle = Bundle(url: applicationURL),
              let installedName = cleaned(
                  bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                      ?? bundle.localizedInfoDictionary?["CFBundleName"] as? String
                      ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                      ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
              ) else { return nil }
        cachedBundleNames[bundleIdentifier] = installedName
        return installedName
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
