import AppKit
import SwiftUI

/// Borderless, non-activating floating panel pinned top-center, just below the
/// menu bar / camera notch. Never becomes key, so Finder keeps focus and its
/// selection.
///
/// The panel is a fixed transparent canvas: switching styles morphs the glass
/// inside it with a spring, so the top-center anchor never moves.
final class CompassHUDPanel: NSPanel {
    static let size = NSSize(width: 540, height: 600)
    /// Gap between the bottom of the menu bar and the top of the glass.
    static let topInset: CGFloat = 8

    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let host = ClickThroughHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Only the preview's style switcher takes clicks; otherwise the HUD is
    /// fully click-through.
    var isInteractive: Bool {
        get { !ignoresMouseEvents }
        set { ignoresMouseEvents = !newValue }
    }

    /// Screen under the pointer, so the HUD follows the user across displays.
    private var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Shows the HUD. With `anchor` (a screen point, e.g. the center of the
    /// selected files) the glass is centered on it, kept fully on screen and
    /// below the menu bar; without, the panel hangs top-center under the
    /// notch. Re-presenting while visible without an anchor keeps the
    /// current position, so the HUD never jumps mid-interaction.
    func present(anchor: CGPoint? = nil) {
        if let anchor {
            let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? activeScreen
            guard let visible = screen?.visibleFrame else { return }
            let top = CompassHUDView.anchorY
            // Largest plate (350 pt) stays clear of the edges.
            let margin: CGFloat = 175 + Self.topInset
            var origin = NSPoint(x: anchor.x - Self.size.width / 2, y: anchor.y + top - Self.size.height)
            let minCenterX = visible.minX + margin, maxCenterX = visible.maxX - margin
            let minCenterY = visible.minY + margin, maxCenterY = visible.maxY - margin
            origin.x = min(max(anchor.x, minCenterX), maxCenterX) - Self.size.width / 2
            origin.y = min(max(anchor.y, minCenterY), maxCenterY) + top - Self.size.height
            setFrame(NSRect(origin: origin, size: Self.size), display: false)
        } else if !isVisible, let screen = activeScreen {
            // Horizontally centered on the whole screen (the notch), top edge
            // on the menu bar, which visibleFrame already excludes.
            let origin = NSPoint(x: screen.frame.midX - Self.size.width / 2,
                                 y: screen.visibleFrame.maxY - Self.size.height)
            setFrame(NSRect(origin: origin, size: Self.size), display: false)
        }

        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
        }
        // Optical glass captures exactly the rectangle under the panel.
        OpticalGlassEngine.shared.track(self, visible: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
                OpticalGlassEngine.shared.track(self, visible: false)
            }
        })
    }
}

/// Lets the first click on the (never-key) panel reach SwiftUI buttons.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
