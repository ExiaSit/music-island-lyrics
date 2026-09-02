import AppKit
import Combine
import SwiftUI

@MainActor
private final class InteractivePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// NSWindow normally keeps a panel inside `visibleFrame`, whose top edge is
    /// below the menu bar. This overlay intentionally occupies the menu-bar
    /// band, so its requested frame must not be pushed down automatically.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class OverlayController {
    static let shared = OverlayController()

    private let panelWidth: CGFloat = 376
    private let panelCenterOffset: CGFloat = -42
    private var collapsedHeight: CGFloat = 38

    private var panel: NSPanel?
    private var visibilityCancellable: AnyCancellable?
    private var presentationCancellable: AnyCancellable?
    private var resignKeyCancellable: AnyCancellable?
    private var hoverTimer: Timer?

    private init() {}

    func start(model: AppModel) {
        guard panel == nil else { return }

        if let screen = targetScreen {
            collapsedHeight = menuBarGeometry(on: screen).height
            model.compactIslandHeight = collapsedHeight
        }

        let panel = InteractivePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = FirstMouseHostingView(rootView: IslandView(model: model))
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        self.panel = panel

        position(panel, extraHeight: 0)
        panel.orderFrontRegardless()
        startHoverTracking(model: model)

        visibilityCancellable = model.$overlayVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                if visible {
                    self?.position(panel, extraHeight: model.islandExtraHeight)
                    panel.orderFrontRegardless()
                } else {
                    panel.orderOut(nil)
                }
            }

        presentationCancellable = model.$islandPresentation
            .removeDuplicates()
            .sink { [weak self, weak panel] presentation in
                guard let self, let panel else { return }
                self.position(panel, extraHeight: model.islandExtraHeight)
                if presentation == .search {
                    panel.makeKeyAndOrderFront(nil)
                }
            }

        resignKeyCancellable = NotificationCenter.default.publisher(
            for: NSWindow.didResignKeyNotification,
            object: panel
        )
        .sink { [weak model] _ in
            Task { @MainActor in
                guard model?.islandPresentation == .search else { return }
                model?.closeSearch()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak panel] _ in
            Task { @MainActor in
                guard let self, let panel, let screen = self.targetScreen else { return }
                self.collapsedHeight = self.menuBarGeometry(on: screen).height
                model.compactIslandHeight = self.collapsedHeight
                self.position(panel, extraHeight: model.islandExtraHeight)
            }
        }
    }

    /// The compact island occupies exactly the system menu-bar band. When it
    /// expands, only the additional content grows below the menu bar.
    private func position(_ panel: NSPanel, extraHeight: CGFloat) {
        guard let screen = targetScreen else { return }
        let geometry = menuBarGeometry(on: screen)
        let frame = NSRect(
            x: screen.frame.midX - panel.frame.width / 2 + panelCenterOffset,
            y: geometry.bottom - extraHeight,
            width: panel.frame.width,
            height: geometry.height + extraHeight
        )
        panel.setFrame(frame, display: true)
    }

    private var targetScreen: NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    private func menuBarGeometry(on screen: NSScreen) -> (bottom: CGFloat, height: CGFloat) {
        let measuredHeight = screen.frame.maxY - screen.visibleFrame.maxY

        // visibleFrame is the authoritative menu-bar boundary. The fallback is
        // only for configurations where an automatically hidden menu bar makes
        // that inset temporarily disappear.
        let height: CGFloat
        if measuredHeight >= 20, measuredHeight <= 64 {
            height = measuredHeight
        } else {
            height = NSStatusBar.system.thickness
        }

        return (screen.frame.maxY - height, height)
    }

    private func setExtraHeight(_ extraHeight: CGFloat) {
        guard let panel else { return }
        guard abs(panel.frame.height - (collapsedHeight + extraHeight)) > 0.5 else { return }
        position(panel, extraHeight: extraHeight)
    }

    private func startHoverTracking(model: AppModel) {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self, weak model] _ in
            Task { @MainActor in
                guard let self, let model, let panel = self.panel else { return }
                guard NSEvent.pressedMouseButtons == 0 else { return }

                if model.islandPresentation == .search {
                    self.setExtraHeight(model.islandExtraHeight)
                    return
                }

                let hovering = panel.frame.contains(NSEvent.mouseLocation)
                model.updateHovering(hovering)
                self.setExtraHeight(model.islandExtraHeight)
            }
        }
    }
}
