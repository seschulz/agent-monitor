import AppKit
import SwiftUI

@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    private static let topLeftDefaultsKey = "overlayTopLeft"

    private let panel: NSPanel
    private var savedTopLeft: NSPoint?
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
        if let saved = UserDefaults.standard.string(forKey: Self.topLeftDefaultsKey), !saved.isEmpty {
            let topLeft = NSPointFromString(saved)
            savedTopLeft = topLeft
            panel.setFrameTopLeftPoint(topLeft)
        } else if let screen = NSScreen.main {
            let frame = panel.frame
            let topLeft = NSPoint(x: screen.visibleFrame.maxX - frame.width - 20, y: screen.visibleFrame.maxY - 20)
            savedTopLeft = topLeft
            panel.setFrameTopLeftPoint(topLeft)
        }
    }

    func updateVisibility(hasSessions: Bool) {
        updateDensity()
        if hasSessions {
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
        panel.setFrameTopLeftPoint(panel.isVisible ? topLeft : (savedTopLeft ?? topLeft))
    }

    func close() {
        savePositionWorkItem?.cancel()
        panel.close()
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
            UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.topLeftDefaultsKey)
            self.userMoveInProgress = false
        }
        savePositionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }
}

private struct OverlayView: View {
    @ObservedObject var store: SessionStore
    let sessionsDidChange: @MainActor () -> Void
    @AppStorage("overlayDensity") private var densityRawValue = OverlayDensity.standard.rawValue

    private var density: OverlayDensity {
        OverlayDensity(rawValue: densityRawValue) ?? .standard
    }

    private var dismissibleSessionIDs: Set<String> {
        Set(store.overlaySessions.lazy.filter { $0.status == .ready }.map(\.id))
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
                        if session.status == .ready {
                            store.dismiss(session.id)
                            sessionsDidChange()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Dismiss \(session.displayName)")
                    }
                    .buttonStyle(.plain)
                    .font(density == .minimal ? .caption2 : .body)
                    .padding(.trailing, density == .minimal ? 4 : 8)
                    .help("Dismiss notification")
                    .opacity(session.status == .ready ? 1 : 0)
                    .disabled(session.status != .ready)
                    .accessibilityHidden(session.status != .ready)
                }
            }
            if dismissibleSessionIDs.count > 1 {
                Divider().padding(.horizontal, density == .minimal ? 4 : 8)
                HStack {
                    Spacer()
                    Button {
                        store.dismiss(dismissibleSessionIDs)
                        sessionsDidChange()
                    } label: {
                        if density == .minimal {
                            Image(systemName: "xmark.circle")
                                .accessibilityLabel("Clear All")
                        } else {
                            Text("Clear All")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(density == .minimal ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, density == .minimal ? 4 : 8)
                    .padding(.vertical, density == .minimal ? 2 : 5)
                    .help("Dismiss all notifications")
                }
            }
        }
        .padding(density.containerPadding)
        .frame(width: density.width)
        .background(.ultraThinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.3)))
    }
}
