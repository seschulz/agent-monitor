import AppKit
@preconcurrency import ApplicationServices
import AgentMonitorShared
import SwiftUI

enum OverlayDensity: String, CaseIterable, Identifiable {
    case compact
    case standard
    case spacious

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var width: CGFloat {
        switch self {
        case .compact: 235
        case .standard: 280
        case .spacious: 320
        }
    }

    var rowPadding: CGFloat {
        switch self {
        case .compact: 2
        case .standard: 5
        case .spacious: 5
        }
    }

    var containerPadding: CGFloat {
        switch self {
        case .compact: 2
        case .standard: 4
        case .spacious: 4
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .compact: 0
        case .standard: 0
        case .spacious: 2
        }
    }

    var titleSize: CGFloat {
        switch self {
        case .compact: 10
        case .standard: 12
        case .spacious: 13
        }
    }

    var detailSize: CGFloat {
        switch self {
        case .compact: 9
        case .standard: 10
        case .spacious: 11
        }
    }

    static func migrateLegacyPreference(in defaults: UserDefaults = .standard) {
        let migrationKey = "overlayDensityNamingVersion"
        guard defaults.integer(forKey: migrationKey) < 1 else { return }

        if let legacyValue = defaults.object(forKey: "overlayDensity") as? String {
            let migratedValue: OverlayDensity
            switch legacyValue {
            case "minimal": migratedValue = .compact
            case "compact": migratedValue = .standard
            case "standard", "spacious": migratedValue = .spacious
            default: migratedValue = .standard
            }
            defaults.set(migratedValue.rawValue, forKey: "overlayDensity")
        }
        defaults.set(1, forKey: migrationKey)
    }

    static var current: OverlayDensity {
        guard let value = UserDefaults.standard.string(forKey: "overlayDensity") else { return .standard }
        return OverlayDensity(rawValue: value) ?? .standard
    }
}

enum OverlayAppearanceStyle: String, CaseIterable, Identifiable {
    case automatic
    case dark
    case light
    case custom

    static let defaultCustomColorHex = "#20242C"

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    func resolvedColorScheme(customColorHex: String, systemColorScheme: ColorScheme) -> ColorScheme {
        switch self {
        case .automatic: systemColorScheme
        case .dark: .dark
        case .light: .light
        case .custom: Self.isDark(hex: customColorHex) ? .dark : .light
        }
    }

    func backgroundColor(customColorHex: String, systemColorScheme: ColorScheme) -> Color {
        switch self {
        case .automatic:
            systemColorScheme == .dark ? .black : .white
        case .dark:
            .black
        case .light:
            .white
        case .custom:
            Self.color(from: customColorHex)
        }
    }

    static func color(from hex: String) -> Color {
        guard let components = rgbComponents(from: hex) else {
            return color(from: defaultCustomColorHex)
        }
        return Color(
            .sRGB,
            red: components.red,
            green: components.green,
            blue: components.blue,
            opacity: 1
        )
    }

    static func hexString(from color: Color) -> String? {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let red = Int((min(max(converted.redComponent, 0), 1) * 255).rounded())
        let green = Int((min(max(converted.greenComponent, 0), 1) * 255).rounded())
        let blue = Int((min(max(converted.blueComponent, 0), 1) * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func isDark(hex: String) -> Bool {
        guard let components = rgbComponents(from: hex) else { return true }
        let luminance = 0.2126 * components.red + 0.7152 * components.green + 0.0722 * components.blue
        return luminance < 0.55
    }

    private static func rgbComponents(from hex: String) -> (red: Double, green: Double, blue: Double)? {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        return (
            Double((number >> 16) & 0xFF) / 255,
            Double((number >> 8) & 0xFF) / 255,
            Double(number & 0xFF) / 255
        )
    }
}

struct OverlayAppearanceBackground: View {
    let style: OverlayAppearanceStyle
    let opacity: Double
    let customColorHex: String
    let highContrast: Bool
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        Group {
            if style == .automatic {
                shape.fill(.ultraThinMaterial).opacity(clampedOpacity)
            } else {
                shape.fill(
                    style.backgroundColor(
                        customColorHex: customColorHex,
                        systemColorScheme: systemColorScheme
                    ).opacity(clampedOpacity)
                )
            }
        }
        .overlay(
            shape.stroke(
                borderColor.opacity(borderOpacity),
                lineWidth: borderWidth
            )
        )
    }

    private var clampedOpacity: Double {
        min(max(opacity, 0.3), 1)
    }

    private var borderWidth: CGFloat {
        switch style {
        case .dark, .custom:
            highContrast ? 0.75 : 0.5
        case .light:
            highContrast ? 0.6 : 0.4
        case .automatic:
            highContrast ? 1.25 : 1
        }
    }

    private var borderOpacity: Double {
        switch style {
        case .dark:
            highContrast ? 0.28 : 0.16
        case .light:
            highContrast ? 0.55 : 0.35
        case .custom:
            highContrast ? 0.45 : 0.28
        case .automatic:
            highContrast ? 0.55 : 0.3
        }
    }

    private var borderColor: Color {
        switch style {
        case .light, .custom:
            .white
        case .automatic, .dark:
            .primary
        }
    }
}

private struct OverlayAppearancePreview: View {
    let style: OverlayAppearanceStyle
    let opacity: Double
    let customColorHex: String
    let highContrast: Bool
    @Environment(\.colorScheme) private var systemColorScheme

    private var effectiveColorScheme: ColorScheme {
        style.resolvedColorScheme(
            customColorHex: customColorHex,
            systemColorScheme: systemColorScheme
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Example project")
                    .font(.system(size: 12, weight: .medium))
                Text("Ready · Codex · Terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .contrast(highContrast ? 1.2 : 1)
        .background {
            OverlayAppearanceBackground(
                style: style,
                opacity: opacity,
                customColorHex: customColorHex,
                highContrast: highContrast
            )
        }
        .environment(\.colorScheme, effectiveColorScheme)
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
            do { try await TerminalFocusService.focus(session) }
            catch {
                if session.terminal.kind.isJetBrains {
                    store.showMessage(error.localizedDescription)
                    return
                }
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
        .help("\(session.displayName)\n\(session.attentionReason ?? session.status.label) · \(session.provider.displayName) · \(session.terminal.displayName)\n\(session.cwd)")
        .frame(height: compact ? nil : menuBarDensity.rowHeight)
    }

    @ViewBuilder
    private var rowContent: some View {
        if compact && overlayDensity == .compact {
            HStack(spacing: 3) {
                Image(systemName: session.status.symbol)
                    .font(.system(size: 11, weight: .semibold))
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
                    Text(Self.compactTime(for: session, at: context.date))
                        .font(.system(size: overlayDensity.detailSize, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                }
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: session.status.symbol)
                    .foregroundStyle(session.status.color)
                    .frame(width: 20)
                    .accessibilityLabel(session.status.accessibilityLabel)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Text(session.displayName)
                            .font(.system(size: compact ? overlayDensity.titleSize : menuBarDensity.titleSize, weight: .medium))
                            .lineLimit(1)
                            .layoutPriority(1)
                        if compact {
                            Spacer(minLength: 3)
                            Text("\(session.provider.displayName) · \(session.terminal.displayName)")
                                .font(.system(size: overlayDensity.detailSize))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
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
            Text(session.attentionReason ?? session.status.label)
                .foregroundStyle(session.status == .attention ? Color.orange : Color.secondary)
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

    nonisolated static func compactTime(for session: SessionRecord, at date: Date) -> String {
        let referenceDate = session.status == .running ? session.startedAt : session.updatedAt
        let seconds = max(0, Int(date.timeIntervalSince(referenceDate)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, integrations, alerts, appearance
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: "General"
        case .integrations: "Integrations"
        case .alerts: "Alerts & Voice"
        case .appearance: "Appearance"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .integrations: "terminal"
        case .alerts: "bell.badge"
        case .appearance: "rectangle.on.rectangle"
        }
    }
    var detail: String {
        switch self {
        case .general: "Startup, updates, and local session history."
        case .integrations: "Connect your agents and choose how sessions open."
        case .alerts: "Decide what deserves your attention—and how you hear it."
        case .appearance: "Make the menu bar and floating widget feel right for you."
        }
    }
}

struct SettingsView: View {
    @ObservedObject var runtime: MonitorRuntime
    @ObservedObject private var updateService: UpdateService
    @State private var selectedPane = SettingsPane.general
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @AppStorage("intellijTabSwitchingEnabled") private var intellijTabSwitchingEnabled = true
    @AppStorage("overlayEnabled") private var overlayEnabled = true
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("inputNotificationsEnabled") private var inputNotificationsEnabled = false
    @AppStorage("permissionNotificationsEnabled") private var permissionNotificationsEnabled = false
    @AppStorage("codexPermissionAlertsEnabled") private var codexPermissionAlertsEnabled = false
    @AppStorage("claudePermissionAlertsEnabled") private var claudePermissionAlertsEnabled = true
    @State private var selectedAlert = AlertTrigger.finished
    @State private var previewAgent = AgentProvider.codex
    @AppStorage("readyRetentionMinutes") private var readyRetentionMinutes = 15
    @AppStorage("showReadyInOverlay") private var showReadyInOverlay = true
    @AppStorage("overlayRetentionMinutes") private var overlayRetentionMinutes = 5
    @AppStorage("speechEnabled") private var speechEnabled = false
    @AppStorage("speakOnInput") private var speakOnInput = true
    @AppStorage("speakOnPermission") private var speakOnPermission = true
    @AppStorage("speakOnCompletion") private var speakOnCompletion = true
    @AppStorage("speechVoice") private var speechVoice = SpeechService.systemDefaultVoice
    @AppStorage("speechCompletionTemplate") private var speechCompletionTemplate = AlertTrigger.finished.defaultMessage
    @AppStorage("speechInputTemplate") private var speechInputTemplate = AlertTrigger.input.defaultMessage
    @AppStorage("speechPermissionTemplate") private var speechPermissionTemplate = AlertTrigger.permission.defaultMessage
    @AppStorage("overlayDensity") private var overlayDensity = OverlayDensity.standard.rawValue
    @AppStorage("overlayAppearanceStyle") private var overlayAppearanceStyle = OverlayAppearanceStyle.automatic.rawValue
    @AppStorage("overlayBackgroundOpacity") private var overlayBackgroundOpacity = 0.8
    @AppStorage("overlayCustomColor") private var overlayCustomColor = OverlayAppearanceStyle.defaultCustomColorHex
    @AppStorage("overlayHighContrast") private var overlayHighContrast = true
    @AppStorage("menuBarDensity") private var menuBarDensity = MenuBarDensity.standard.rawValue
    @AppStorage("showTerminalInMenuBar") private var showTerminalInMenuBar = true

    init(runtime: MonitorRuntime) {
        self.runtime = runtime
        _updateService = ObservedObject(wrappedValue: runtime.updateService)
    }

    private var selectedOverlayAppearance: OverlayAppearanceStyle {
        OverlayAppearanceStyle(rawValue: overlayAppearanceStyle) ?? .automatic
    }

    private var overlayCustomColorBinding: Binding<Color> {
        Binding(
            get: { OverlayAppearanceStyle.color(from: overlayCustomColor) },
            set: { color in
                if let hex = OverlayAppearanceStyle.hexString(from: color) {
                    overlayCustomColor = hex
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent Monitor").font(.headline)
                    Text("Settings").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.top, 24)

                VStack(spacing: 5) {
                    ForEach(SettingsPane.allCases) { pane in
                        Button {
                            selectedPane = pane
                        } label: {
                            Label(pane.label, systemImage: pane.symbol)
                                .font(.system(size: 13, weight: selectedPane == pane ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 11)
                                .background(selectedPane == pane ? Color.accentColor.opacity(0.14) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .foregroundStyle(selectedPane == pane ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedPane == pane ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 10)
                Spacer()
            }
            .frame(width: 178)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedPane.label).font(.system(size: 25, weight: .bold))
                    Text(selectedPane.detail).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 12)
                Form {
                    switch selectedPane {
                    case .general:
                        generalSettings
                        advancedSettings
                    case .integrations:
                        integrationSettings
                    case .appearance:
                        interfaceSettings
                    case .alerts:
                        alertSettings
                    }
                }
                .formStyle(.grouped)
                .id(selectedPane)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, idealWidth: 840, minHeight: 650, idealHeight: 780)
        .onAppear { accessibilityGranted = AXIsProcessTrusted() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    @ViewBuilder
    private var generalSettings: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: Binding(
                get: { runtime.launchAtLoginEnabled },
                set: { runtime.setLaunchAtLogin($0) }
            ))
            if runtime.launchAtLoginNeedsApproval {
                HStack {
                    Text("Allow Agent Monitor in Login Items to launch it automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") { runtime.openLoginItemSettings() }
                }
            }
        }

        Section("Software Updates") {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updateService.automaticallyChecksForUpdates },
                set: { updateService.setAutomaticallyChecksForUpdates($0) }
            ))
            HStack {
                LabeledContent("Installed version", value: updateService.currentVersion)
                Spacer()
                Button("Check for Updates…") { updateService.checkNow() }
                    .disabled(!updateService.canCheckForUpdates)
            }
            Text("Updates come from GitHub Releases and are verified by Sparkle before installation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var integrationSettings: some View {
        Section("Agent Integrations") {
            Text("Hooks let Codex and Claude Code report session activity to Agent Monitor.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                LabeledContent(
                    "Codex and Claude Code",
                    value: runtime.integrationsInstalled ? "Installed" : "Not installed"
                )
                Spacer()
                if runtime.integrationsInstalled {
                    Button("Remove Hooks") { runtime.removeIntegrations() }
                } else {
                    Button("Install Hooks") { _ = runtime.installIntegrations() }
                }
            }
            if let message = runtime.integrationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Terminal Navigation") {
            Toggle("Switch to the agent’s IDE terminal tab", isOn: $intellijTabSwitchingEnabled)
            Text("Uses Accessibility access to select the connected tab in IntelliJ IDEA and Rider when you click a session.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !intellijTabSwitchingEnabled {
                Text("Clicks open the IDE without changing terminal tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if accessibilityGranted {
                Label("Accessibility access enabled", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Accessibility access is off. Clicks still open the IDE, without selecting a tab or showing a permission prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Accessibility Settings…") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    accessibilityGranted = AXIsProcessTrustedWithOptions(options)
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

    }

    @ViewBuilder
    private var interfaceSettings: some View {
        Section("Menu Bar") {
            Text("Customize the session list that opens from the menu bar icon.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Session row size", selection: $menuBarDensity) {
                ForEach(MenuBarDensity.allCases) { density in
                    Text(density.label).tag(density.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Show agent and terminal names", isOn: $showTerminalInMenuBar)
            Stepper("Keep finished sessions for \(readyRetentionMinutes) minutes", value: $readyRetentionMinutes, in: 1...120)
        }

        Section("Floating Widget") {
            Text("Show active and recently finished sessions above other windows.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show floating widget", isOn: $overlayEnabled)
                .onChange(of: overlayEnabled) { _, _ in runtime.refreshOverlay() }
            Picker("Widget size", selection: $overlayDensity) {
                ForEach(OverlayDensity.allCases) { density in
                    Text(density.label).tag(density.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!overlayEnabled)
            .onChange(of: overlayDensity) { _, _ in runtime.refreshOverlay() }
            Toggle("Show finished sessions", isOn: $showReadyInOverlay)
                .disabled(!overlayEnabled)
                .onChange(of: showReadyInOverlay) { _, _ in runtime.refreshOverlay() }
            Stepper(
                "Hide finished sessions after \(overlayRetentionMinutes) minutes",
                value: $overlayRetentionMinutes,
                in: 1...120
            )
            .disabled(!overlayEnabled || !showReadyInOverlay)
            .onChange(of: overlayRetentionMinutes) { _, _ in runtime.refreshOverlay() }
        }

        Section("Widget Appearance") {
            Text("Choose a background that stays readable over bright and dark windows.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Background style", selection: $overlayAppearanceStyle) {
                ForEach(OverlayAppearanceStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!overlayEnabled)
            HStack {
                Text("Background opacity")
                Slider(value: $overlayBackgroundOpacity, in: 0.3...1, step: 0.05)
                Text("\(Int((overlayBackgroundOpacity * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .disabled(!overlayEnabled)
            if selectedOverlayAppearance == .custom {
                ColorPicker(
                    "Background color",
                    selection: overlayCustomColorBinding,
                    supportsOpacity: false
                )
                .disabled(!overlayEnabled)
            }
            Toggle("Increase text contrast", isOn: $overlayHighContrast)
                .disabled(!overlayEnabled)
            LabeledContent("Preview") {
                OverlayAppearancePreview(
                    style: selectedOverlayAppearance,
                    opacity: overlayBackgroundOpacity,
                    customColorHex: overlayCustomColor,
                    highContrast: overlayHighContrast
                )
                .frame(width: 245)
            }
            .disabled(!overlayEnabled)
        }
    }

    @ViewBuilder
    private var alertSettings: some View {
        Section("Voice") {
            Toggle("Enable spoken alerts", isOn: $speechEnabled)
            Picker("Voice", selection: $speechVoice) {
                ForEach(SpeechService.availableVoices, id: \.self) { voice in
                    Text(voice).tag(voice)
                }
            }
            .disabled(!speechEnabled)
        }

        Section("Choose a trigger") {
            Picker("Alert trigger", selection: $selectedAlert) {
                ForEach(AlertTrigger.allCases) { trigger in
                    Label(trigger.label, systemImage: trigger.symbol).tag(trigger)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        Section {
            if selectedAlert == .permission {
                Toggle("Codex permission alerts", isOn: $codexPermissionAlertsEnabled)
                    .onChange(of: codexPermissionAlertsEnabled) { _, value in
                        runtime.store.setPermissionAlertsEnabled(value, for: .codex)
                    }
                Toggle("Claude Code permission alerts", isOn: $claudePermissionAlertsEnabled)
                    .onChange(of: claudePermissionAlertsEnabled) { _, value in
                        runtime.store.setPermissionAlertsEnabled(value, for: .claude)
                    }
                Text("Defaults: Codex off, Claude Code on. Turning an agent off silences permission alerts and clears its permission indicators. Input questions still alert normally.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Show a macOS notification", isOn: notificationBinding)
                .disabled(permissionDeliveryDisabled)
            Toggle("Speak this alert", isOn: triggerSpeechBinding)
                .disabled(!speechEnabled || permissionDeliveryDisabled)
            if permissionDeliveryDisabled {
                Text("Enable permission alerts for an agent above to use these delivery options.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !speechEnabled {
                Text("Enable spoken alerts above to hear this message.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(selectedAlert.title)
        } footer: {
            Text(selectedAlert.detail)
        }

        Section("Spoken message") {
            TextField("Message for \(selectedAlert.label.lowercased())", text: templateBinding, axis: .vertical)
                .labelsHidden()
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .accessibilityLabel("\(selectedAlert.label) spoken message")
            Text("Use {agent}, {project}, {terminal}, or {directory}. Leave blank for the default message.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Preview as", selection: $previewAgent) {
                    Text("Codex").tag(AgentProvider.codex)
                    Text("Claude Code").tag(AgentProvider.claude)
                }
                .frame(maxWidth: 230)
                Spacer()
                Button {
                    SpeechService.speak(speechPreview, voice: speechVoice)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .disabled(!speechEnabled)
                .help("Play a preview using the selected voice")
            }
            Text(speechPreview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityLabel("Message preview: \(speechPreview)")
            HStack {
                Spacer()
                Button("Reset message") { templateBinding.wrappedValue = selectedAlert.defaultMessage }
                    .disabled(templateBinding.wrappedValue == selectedAlert.defaultMessage)
            }
        }
    }

    private var permissionDeliveryDisabled: Bool {
        selectedAlert == .permission && !codexPermissionAlertsEnabled && !claudePermissionAlertsEnabled
    }

    private var notificationBinding: Binding<Bool> {
        Binding(get: {
            switch selectedAlert {
            case .finished: notificationsEnabled
            case .input: inputNotificationsEnabled
            case .permission: permissionNotificationsEnabled
            }
        }, set: { value in
            switch selectedAlert {
            case .finished: notificationsEnabled = value
            case .input: inputNotificationsEnabled = value
            case .permission: permissionNotificationsEnabled = value
            }
            runtime.requestNotifications(value, preference: selectedAlert.notificationKey)
        })
    }

    private var triggerSpeechBinding: Binding<Bool> {
        Binding(get: {
            switch selectedAlert {
            case .finished: speakOnCompletion
            case .input: speakOnInput
            case .permission: speakOnPermission
            }
        }, set: { value in
            switch selectedAlert {
            case .finished: speakOnCompletion = value
            case .input: speakOnInput = value
            case .permission: speakOnPermission = value
            }
        })
    }

    private var templateBinding: Binding<String> {
        Binding(get: {
            switch selectedAlert {
            case .finished: speechCompletionTemplate
            case .input: speechInputTemplate
            case .permission: speechPermissionTemplate
            }
        }, set: { value in
            switch selectedAlert {
            case .finished: speechCompletionTemplate = value
            case .input: speechInputTemplate = value
            case .permission: speechPermissionTemplate = value
            }
        })
    }

    @ViewBuilder
    private var advancedSettings: some View {
        Section("Session Data") {
            Text("Session history and internal state are stored locally on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Data folder") {
                Text(AppPaths.baseDirectory.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Clear Session History") { runtime.store.clearAll() }
                Spacer()
                Button("Open Data Folder") { NSWorkspace.shared.open(AppPaths.baseDirectory) }
            }
        }
    }

    private var speechPreview: String {
        SpeechMessageTemplate.render(
            templateBinding.wrappedValue,
            agent: previewAgent.displayName,
            project: "agent-monitor",
            terminal: "Terminal",
            directory: "/Users/example/agent-monitor",
            fallback: selectedAlert.defaultMessage
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
        case .rider: "Rider"
        case .vscode, .unknown:
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
