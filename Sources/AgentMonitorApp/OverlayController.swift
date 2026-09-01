import AppKit
import SwiftUI

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    private static let topLeftDefaultsKey = "overlayTopLeft"
    private static let positionAnchorDefaultsKey = "overlayPositionAnchor"

    struct PositionAnchor: Codable, Equatable {
        enum HorizontalEdge: String, Codable {
            case left
            case right
        }

        enum VerticalEdge: String, Codable {
            case top
            case bottom
        }

        let screenID: UInt32?
        let horizontalEdge: HorizontalEdge
        let horizontalInset: CGFloat
        let verticalEdge: VerticalEdge
        let verticalInset: CGFloat
    }

    private let panel: NSPanel
    private var savedTopLeft: NSPoint?
    private var savedPositionAnchor: PositionAnchor?
    private var userMoveInProgress = false
    private var savePositionWorkItem: DispatchWorkItem?

    init(store: SessionStore, sessionsDidChange: @escaping @MainActor () -> Void) {
        let density = OverlayDensity.current
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: density.width, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OverlayView(store: store, sessionsDidChange: sessionsDidChange))
        if let anchor = Self.loadPositionAnchor(),
           let screen = Self.screen(matching: anchor.screenID) ?? NSScreen.main {
            let topLeft = Self.topLeft(for: anchor, windowSize: panel.frame.size, visibleFrame: screen.visibleFrame)
            savedPositionAnchor = anchor
            savedTopLeft = topLeft
            panel.setFrameTopLeftPoint(topLeft)
        } else if let saved = UserDefaults.standard.string(forKey: Self.topLeftDefaultsKey), !saved.isEmpty {
            let topLeft = NSPointFromString(saved)
            savedTopLeft = topLeft
            panel.setFrameTopLeftPoint(topLeft)
        } else if let screen = NSScreen.main {
            let frame = panel.frame
            let topLeft = NSPoint(x: screen.visibleFrame.maxX - frame.width - 20, y: screen.visibleFrame.maxY - 20)
            savedTopLeft = topLeft
            panel.setFrameTopLeftPoint(topLeft)
        }
        ensureOnScreen()
        persistCurrentPosition()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func updateVisibility(hasSessions: Bool) {
        updateDensity()
        if hasSessions {
            ensureOnScreen()
            if !panel.isVisible, let savedTopLeft {
                panel.setFrameTopLeftPoint(savedTopLeft)
            }
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func updateDensity() {
        let width = OverlayDensity.current.width
        guard abs(panel.frame.width - width) > 0.5 else { return }
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(NSSize(width: width, height: panel.contentRect(forFrameRect: panel.frame).height))
        if savedPositionAnchor != nil {
            restoreAnchoredPosition()
        } else {
            panel.setFrameTopLeftPoint(panel.isVisible ? topLeft : (savedTopLeft ?? topLeft))
            ensureOnScreen()
            persistCurrentPosition()
        }
    }

    func close() {
        savePositionWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        panel.close()
    }

    @objc private func screenParametersDidChange() {
        restoreAnchoredPosition()
    }

    private func ensureOnScreen() {
        let topLeft = savedTopLeft ?? NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let corrected = Self.reachableTopLeft(
            topLeft,
            windowSize: panel.frame.size,
            visibleFrames: visibleFrames,
            preferredVisibleFrame: NSScreen.main?.visibleFrame
        )
        guard corrected != topLeft else { return }

        savePositionWorkItem?.cancel()
        userMoveInProgress = false
        savedTopLeft = corrected
        panel.setFrameTopLeftPoint(corrected)
        persistCurrentPosition()
    }

    static func reachableTopLeft(
        _ topLeft: NSPoint,
        windowSize: NSSize,
        visibleFrames: [NSRect],
        preferredVisibleFrame: NSRect?
    ) -> NSPoint {
        guard !visibleFrames.isEmpty else { return topLeft }
        let windowFrame = NSRect(
            x: topLeft.x,
            y: topLeft.y - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
        let minimumVisibleWidth = min(48, max(windowSize.width * 0.2, 1))
        let minimumVisibleHeight = min(32, max(windowSize.height * 0.2, 1))
        if visibleFrames.contains(where: {
            let intersection = $0.intersection(windowFrame)
            return intersection.width >= minimumVisibleWidth && intersection.height >= minimumVisibleHeight
        }) {
            return topLeft
        }

        let target = preferredVisibleFrame ?? visibleFrames[0]
        let margin: CGFloat = 20
        let minimumX = target.minX + margin
        let maximumX = max(minimumX, target.maxX - windowSize.width - margin)
        let minimumY = target.minY + windowSize.height + margin
        let maximumY = max(minimumY, target.maxY - margin)
        return NSPoint(
            x: min(max(topLeft.x, minimumX), maximumX),
            y: min(max(topLeft.y, minimumY), maximumY)
        )
    }

    static func positionAnchor(
        for topLeft: NSPoint,
        windowSize: NSSize,
        visibleFrame: NSRect,
        screenID: UInt32? = nil
    ) -> PositionAnchor {
        let windowFrame = NSRect(
            x: topLeft.x,
            y: topLeft.y - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
        let leftInset = max(0, windowFrame.minX - visibleFrame.minX)
        let rightInset = max(0, visibleFrame.maxX - windowFrame.maxX)
        let topInset = max(0, visibleFrame.maxY - windowFrame.maxY)
        let bottomInset = max(0, windowFrame.minY - visibleFrame.minY)
        return PositionAnchor(
            screenID: screenID,
            horizontalEdge: leftInset <= rightInset ? .left : .right,
            horizontalInset: min(leftInset, rightInset),
            verticalEdge: topInset <= bottomInset ? .top : .bottom,
            verticalInset: min(topInset, bottomInset)
        )
    }

    static func topLeft(for anchor: PositionAnchor, windowSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        let x = switch anchor.horizontalEdge {
        case .left: visibleFrame.minX + anchor.horizontalInset
        case .right: visibleFrame.maxX - windowSize.width - anchor.horizontalInset
        }
        let y = switch anchor.verticalEdge {
        case .top: visibleFrame.maxY - anchor.verticalInset
        case .bottom: visibleFrame.minY + windowSize.height + anchor.verticalInset
        }
        return NSPoint(x: x, y: y)
    }

    private func restoreAnchoredPosition() {
        guard let anchor = savedPositionAnchor,
              let screen = Self.screen(matching: anchor.screenID) ?? NSScreen.main else {
            ensureOnScreen()
            persistCurrentPosition()
            return
        }
        let requested = Self.topLeft(for: anchor, windowSize: panel.frame.size, visibleFrame: screen.visibleFrame)
        let corrected = Self.reachableTopLeft(
            requested,
            windowSize: panel.frame.size,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            preferredVisibleFrame: screen.visibleFrame
        )
        savePositionWorkItem?.cancel()
        userMoveInProgress = false
        savedTopLeft = corrected
        panel.setFrameTopLeftPoint(corrected)
        persistCurrentPosition(preferredScreen: screen)
    }

    private func persistCurrentPosition(preferredScreen: NSScreen? = nil) {
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        guard let screen = preferredScreen ?? Self.screen(containing: panel.frame) ?? NSScreen.main else { return }
        let anchor = Self.positionAnchor(
            for: topLeft,
            windowSize: panel.frame.size,
            visibleFrame: screen.visibleFrame,
            screenID: Self.displayID(for: screen)
        )
        savedTopLeft = topLeft
        savedPositionAnchor = anchor
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.topLeftDefaultsKey)
        if let data = try? JSONEncoder().encode(anchor) {
            UserDefaults.standard.set(data, forKey: Self.positionAnchorDefaultsKey)
        }
    }

    private static func loadPositionAnchor() -> PositionAnchor? {
        guard let data = UserDefaults.standard.data(forKey: positionAnchorDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(PositionAnchor.self, from: data)
    }

    private static func screen(matching displayID: UInt32?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { Self.displayID(for: $0) == displayID }
    }

    private static func screen(containing windowFrame: NSRect) -> NSScreen? {
        let screen = NSScreen.screens.max { lhs, rhs in
            let lhsIntersection = lhs.visibleFrame.intersection(windowFrame)
            let rhsIntersection = rhs.visibleFrame.intersection(windowFrame)
            return lhsIntersection.width * lhsIntersection.height < rhsIntersection.width * rhsIntersection.height
        }
        guard let screen else { return nil }
        let intersection = screen.visibleFrame.intersection(windowFrame)
        return intersection.width * intersection.height > 0 ? screen : nil
    }

    private static func displayID(for screen: NSScreen) -> UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    func windowWillMove(_ notification: Notification) {
        userMoveInProgress = true
        savePositionWorkItem?.cancel()
    }

    func windowDidMove(_ notification: Notification) {
        guard userMoveInProgress else { return }

        // AppKit can also move a borderless panel while its SwiftUI content is
        // changing. Wait for a real drag to settle before persisting its anchor.
        savePositionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let topLeft = NSPoint(x: self.panel.frame.minX, y: self.panel.frame.maxY)
            self.savedTopLeft = topLeft
            self.persistCurrentPosition()
            self.userMoveInProgress = false
        }
        savePositionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }
}

private struct OverlayView: View {
    @ObservedObject var store: SessionStore
    let sessionsDidChange: @MainActor () -> Void
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("overlayDensity") private var densityRawValue = OverlayDensity.standard.rawValue
    @AppStorage("overlayAppearanceStyle") private var appearanceRawValue = OverlayAppearanceStyle.automatic.rawValue
    @AppStorage("overlayBackgroundOpacity") private var backgroundOpacity = 0.8
    @AppStorage("overlayCustomColor") private var customColorHex = OverlayAppearanceStyle.defaultCustomColorHex
    @AppStorage("overlayHighContrast") private var highContrast = true

    private var density: OverlayDensity {
        OverlayDensity(rawValue: densityRawValue) ?? .standard
    }

    private var appearance: OverlayAppearanceStyle {
        OverlayAppearanceStyle(rawValue: appearanceRawValue) ?? .automatic
    }

    private var effectiveColorScheme: ColorScheme {
        appearance.resolvedColorScheme(
            customColorHex: customColorHex,
            systemColorScheme: systemColorScheme
        )
    }

    private var dismissibleSessionIDs: Set<String> {
        Set(store.overlaySessions.map(\.id))
    }

    var body: some View {
        VStack(spacing: density.rowSpacing) {
            ForEach(store.overlaySessions) { session in
                HStack(spacing: 0) {
                    SessionRow(session: session, compact: true) {
                        Task {
                            do { try await TerminalFocusService.focus(session.terminal) }
                            catch { store.showMessage(error.localizedDescription) }
                        }
                    }
                    Button {
                        store.dismiss(session.id)
                        sessionsDidChange()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Dismiss \(session.displayName)")
                    }
                    .buttonStyle(.plain)
                    .font(density == .compact ? .caption2 : .body)
                    .padding(.trailing, density == .compact ? 4 : 8)
                    .help("Dismiss session")
                }
            }
            if dismissibleSessionIDs.count > 1 {
                Divider().padding(.horizontal, density == .compact ? 4 : 8)
                HStack {
                    Spacer()
                    Button {
                        store.dismiss(dismissibleSessionIDs)
                        sessionsDidChange()
                    } label: {
                        if density == .compact {
                            Image(systemName: "xmark.circle")
                                .accessibilityLabel("Clear All")
                        } else {
                            Text("Clear All")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(density == .compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, density == .compact ? 4 : 8)
                    .padding(.vertical, density == .compact ? 2 : 5)
                    .help("Dismiss all sessions")
                }
            }
        }
        .padding(density.containerPadding)
        .frame(width: density.width)
        .contrast(highContrast ? 1.2 : 1)
        .background {
            OverlayAppearanceBackground(
                style: appearance,
                opacity: backgroundOpacity,
                customColorHex: customColorHex,
                highContrast: highContrast
            )
        }
        .environment(\.colorScheme, effectiveColorScheme)
    }
}
