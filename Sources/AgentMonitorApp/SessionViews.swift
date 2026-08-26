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
    let onOpenDiagnostics: (String?) -> Void
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
            .contentShape(Rectangle())
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.option) {
                    onOpenDiagnostics(nil)
                }
            }
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
                        ) {
                            if NSEvent.modifierFlags.contains(.option) {
                                onOpenDiagnostics(session.id)
                            } else {
                                focus(session)
                            }
                        }
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

@MainActor
final class DiagnosticsWindowState: ObservableObject {
    @Published var selectedSessionID: String?

    init(selectedSessionID: String? = nil) {
        self.selectedSessionID = selectedSessionID
    }
}

struct DiagnosticTimelineView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var state: DiagnosticsWindowState

    private var summaries: [DiagnosticSessionSummary] {
        store.diagnosticSessionSummaries
    }

    var body: some View {
        HSplitView {
            List(selection: $state.selectedSessionID) {
                ForEach(summaries) { summary in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(summary.provider.displayName)
                            Text("·")
                            Text("\(summary.eventCount) events")
                            Text("·")
                            Text(summary.updatedAt, style: .relative)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .padding(.vertical, 3)
                    .tag(summary.id)
                }
            }
            .frame(minWidth: 210, idealWidth: 240, maxWidth: 290)

            timeline
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 500)
        .onAppear(perform: selectFirstSessionIfNeeded)
        .onChange(of: summaries.map(\.id)) { _, _ in
            selectFirstSessionIfNeeded()
        }
    }

    @ViewBuilder
    private var timeline: some View {
        if let sessionID = state.selectedSessionID,
           let summary = summaries.first(where: { $0.id == sessionID }) {
            let entries = store.diagnosticEntries(for: sessionID)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.displayName)
                            .font(.title2.weight(.semibold))
                        Text(sessionID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Copy JSON") { copyJSON(for: sessionID) }
                    Button("Clear") { store.clearDiagnostics(for: sessionID) }
                }
                .padding(16)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            DiagnosticTimelineRow(entry: entry)
                            if entry.id != entries.last?.id { Divider() }
                        }
                    }
                }
            }
        } else if summaries.isEmpty {
            ContentUnavailableView(
                "No diagnostic events",
                systemImage: "waveform.path.ecg",
                description: Text("Lifecycle events will appear here as agents run.")
            )
        } else {
            ContentUnavailableView("Select a session", systemImage: "sidebar.left")
        }
    }

    private func selectFirstSessionIfNeeded() {
        guard !summaries.contains(where: { $0.id == state.selectedSessionID }) else { return }
        state.selectedSessionID = summaries.first?.id
    }

    private func copyJSON(for sessionID: String) {
        guard let json = store.diagnosticJSON(for: sessionID) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }
}

private struct DiagnosticTimelineRow: View {
    let entry: DiagnosticTimelineEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(outcomeColor)
                    .frame(width: 8, height: 8)
                Text(entry.event.eventType.rawValue)
                    .font(.body.monospaced().weight(.medium))
                Text(entry.outcome.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(outcomeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(outcomeColor.opacity(0.12), in: Capsule())
                Spacer()
                Text(entry.receivedAt.formatted(.dateTime.hour().minute().second()))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 5) {
                Text(statusTransition)
                if let turnID = entry.event.turnId {
                    Text("·")
                    Text("turn \(turnID)")
                }
                if let toolName = entry.event.toolName {
                    Text("·")
                    Text("tool \(toolName)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if entry.completionSignalEmitted {
                HStack(spacing: 5) {
                    Label("menu-bar completion", systemImage: "checkmark.circle")
                    if entry.notificationTriggered {
                        Text("·")
                        Label("notification", systemImage: "bell")
                    }
                    if entry.speechTriggered {
                        Text("·")
                        Label("speech", systemImage: "speaker.wave.2")
                    }
                }
                .font(.caption)
                .foregroundStyle(.blue)
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                diagnosticField("event", entry.event.eventId)
                diagnosticField("occurred", entry.event.occurredAt.formatted(.iso8601))
                diagnosticField("cwd", entry.event.cwd)
                diagnosticField("terminal", terminalDescription)
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusTransition: String {
        let previous = entry.previousStatus?.rawValue ?? "none"
        let resulting = entry.resultingStatus?.rawValue ?? "none"
        return "\(previous) → \(resulting) (reported \(entry.event.status.rawValue))"
    }

    private var terminalDescription: String {
        var values = [entry.event.terminal.kind.rawValue]
        if let bundleID = entry.event.terminal.bundleIdentifier { values.append(bundleID) }
        if let pid = entry.event.terminal.agentPid { values.append("pid=\(pid)") }
        if let tty = entry.event.terminal.tty { values.append(tty) }
        return values.joined(separator: " · ")
    }

    private var outcomeColor: Color {
        entry.outcome == .applied ? .green : .orange
    }

    private func diagnosticField(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .frame(width: 58, alignment: .trailing)
            Text(value)
                .lineLimit(1)
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
        let referenceDate = session.status == .running ? session.startedAt : session.updatedAt
        let seconds = max(0, Int(date.timeIntervalSince(referenceDate)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }
}

struct SettingsView: View {
    @ObservedObject var runtime: MonitorRuntime
    @ObservedObject private var updateService: UpdateService
    @AppStorage("overlayEnabled") private var overlayEnabled = true
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("readyRetentionMinutes") private var readyRetentionMinutes = 15
    @AppStorage("showReadyInOverlay") private var showReadyInOverlay = true
    @AppStorage("overlayRetentionMinutes") private var overlayRetentionMinutes = 5
    @AppStorage("speechEnabled") private var speechEnabled = false
    @AppStorage("speakOnCompletion") private var speakOnCompletion = true
    @AppStorage("speechVoice") private var speechVoice = SpeechService.systemDefaultVoice
    @AppStorage("speechCompletionTemplate") private var speechCompletionTemplate = CompletionSpeechTemplate.defaultValue
    @AppStorage("overlayDensity") private var overlayDensity = OverlayDensity.standard.rawValue
    @AppStorage("menuBarDensity") private var menuBarDensity = MenuBarDensity.standard.rawValue
    @AppStorage("showTerminalInMenuBar") private var showTerminalInMenuBar = true

    init(runtime: MonitorRuntime) {
        self.runtime = runtime
        _updateService = ObservedObject(wrappedValue: runtime.updateService)
    }

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

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updateService.automaticallyChecksForUpdates },
                    set: { updateService.setAutomaticallyChecksForUpdates($0) }
                ))
                HStack {
                    LabeledContent("Current version", value: updateService.currentVersion)
                    Spacer()
                    Button("Check for Updates…") { updateService.checkNow() }
                        .disabled(!updateService.canCheckForUpdates)
                }
                Text("Sparkle checks GitHub Releases and verifies every update before installing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("macOS Alerts") {
                Text("Agent Monitor can post a standard macOS notification when an agent finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Notify when an agent finishes", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, value in runtime.requestNotifications(value) }
            }

            Section("Finished Voice Alerts") {
                Text("Voice alerts are spoken only when an agent turn finishes. Ongoing activity and tool calls stay silent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Speak when an agent finishes", isOn: completionSpeechEnabled)
                Picker("Voice", selection: $speechVoice) {
                    ForEach(SpeechService.availableVoices, id: \.self) { voice in
                        Text(voice).tag(voice)
                    }
                }
                .disabled(!completionSpeechEnabled.wrappedValue)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom message (optional)")
                        .font(.subheadline)
                    TextField("Leave empty to use the default message", text: $speechCompletionTemplate)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 4) {
                        Text("Default:")
                        Text(CompletionSpeechTemplate.defaultValue)
                            .monospaced()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text("Placeholders: {agent}, {project}, {terminal}, {directory}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text("Preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(completionSpeechPreview)
                        .textSelection(.enabled)
                }
                .disabled(!completionSpeechEnabled.wrappedValue)
                Button("Test Voice") {
                    SpeechService.speak(completionSpeechPreview, voice: speechVoice)
                }
                .disabled(!completionSpeechEnabled.wrappedValue)
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
        .frame(width: 600, height: runtime.launchAtLoginNeedsApproval ? 800 : 760)
    }

    private var completionSpeechEnabled: Binding<Bool> {
        Binding(
            get: { speechEnabled && speakOnCompletion },
            set: {
                speechEnabled = $0
                speakOnCompletion = $0
            }
        )
    }

    private var completionSpeechPreview: String {
        CompletionSpeechTemplate.render(
            speechCompletionTemplate,
            agent: "Codex",
            project: "agent-monitor",
            terminal: "Terminal",
            directory: "/Users/example/agent-monitor"
        )
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

extension TerminalHost {
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
