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
    private var displayCancellable: AnyCancellable?
    private var resignKeyCancellable: AnyCancellable?
    private var hoverTimer: Timer?
    private var hoverExitDate: Date?

    private init() {}

    func start(model: AppModel) {
        guard panel == nil else { return }
        model.refreshDisplayOptions()

        if let screen = targetScreen(model: model) {
            collapsedHeight = menuBarGeometry(on: screen).height
            model.compactIslandHeight = collapsedHeight
            model.updateCompactLayout(for: screen)
        }

        let panel = InteractivePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = Self.islandWindowLevel
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

        position(panel, extraHeight: 0, model: model)
        panel.orderFrontRegardless()
        startHoverTracking(model: model)

        visibilityCancellable = model.$overlayVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                if visible {
                    self?.position(panel, extraHeight: model.islandExtraHeight, model: model)
                    panel.level = Self.islandWindowLevel
                    panel.orderFrontRegardless()
                } else {
                    panel.orderOut(nil)
                }
            }

        presentationCancellable = model.$islandPresentation
            .removeDuplicates()
            .sink { [weak self, weak panel] presentation in
                guard let self, let panel else { return }
                self.position(panel, extraHeight: model.islandExtraHeight, model: model)
                if presentation == .search {
                    panel.makeKeyAndOrderFront(nil)
                }
            }

        displayCancellable = model.$selectedDisplayID
            .removeDuplicates()
            .sink { [weak self, weak panel] _ in
                Task { @MainActor in
                    guard let self, let panel else { return }
                    if let screen = self.targetScreen(model: model) {
                        self.collapsedHeight = self.menuBarGeometry(on: screen).height
                        model.compactIslandHeight = self.collapsedHeight
                        model.updateCompactLayout(for: screen)
                    }
                    self.position(panel, extraHeight: model.islandExtraHeight, model: model)
                    panel.level = Self.islandWindowLevel
                    panel.orderFrontRegardless()
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
                guard let self, let panel else { return }
                model.refreshDisplayOptions()
                guard let screen = self.targetScreen(model: model) else { return }
                self.collapsedHeight = self.menuBarGeometry(on: screen).height
                model.compactIslandHeight = self.collapsedHeight
                model.updateCompactLayout(for: screen)
                self.position(panel, extraHeight: model.islandExtraHeight, model: model)
            }
        }
    }

    /// The compact island occupies exactly the system menu-bar band. When it
    /// expands, only the additional content grows below the menu bar.
    private func position(_ panel: NSPanel, extraHeight: CGFloat, model: AppModel) {
        guard let screen = targetScreen(model: model) else { return }
        let geometry = menuBarGeometry(on: screen)
        let frame = NSRect(
            x: screen.frame.midX - panel.frame.width / 2 + panelCenterOffset,
            y: geometry.bottom - extraHeight,
            width: panel.frame.width,
            height: geometry.height + extraHeight
        )
        panel.setFrame(frame, display: true)
    }

    private func targetScreen(model: AppModel) -> NSScreen? {
        if let selectedDisplayID = model.selectedDisplayID {
            return NSScreen.screens.first { $0.overlayDisplayID == selectedDisplayID }
                ?? NSScreen.main
                ?? NSScreen.screens.first
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private static var islandWindowLevel: NSWindow.Level {
        NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
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

    private func setExtraHeight(_ extraHeight: CGFloat, model: AppModel) {
        guard let panel else { return }
        guard abs(panel.frame.height - (collapsedHeight + extraHeight)) > 0.5 else { return }
        position(panel, extraHeight: extraHeight, model: model)
    }

    private func startHoverTracking(model: AppModel) {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self, weak model] _ in
            Task { @MainActor in
                guard let self, let model, let panel = self.panel else { return }
                guard NSEvent.pressedMouseButtons == 0 else { return }
                if model.overlayVisible, !panel.isVisible {
                    panel.orderFrontRegardless()
                }
                panel.level = Self.islandWindowLevel

                if model.islandPresentation == .search {
                    self.setExtraHeight(model.islandExtraHeight, model: model)
                    return
                }

                let hovering = panel.frame.contains(NSEvent.mouseLocation)
                if hovering {
                    self.hoverExitDate = nil
                    model.updateHovering(true)
                } else if model.islandPresentation == .hover {
                    let now = Date()
                    let exitDate = self.hoverExitDate ?? now
                    self.hoverExitDate = exitDate
                    if now.timeIntervalSince(exitDate) >= 0.45 {
                        model.updateHovering(false)
                        self.hoverExitDate = nil
                    }
                } else {
                    self.hoverExitDate = nil
                    model.updateHovering(false)
                }
                self.setExtraHeight(model.islandExtraHeight, model: model)
            }
        }
    }
}
