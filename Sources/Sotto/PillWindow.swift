import AppKit
import ApplicationServices

@MainActor
final class PillWindow {
    private static let size = NSSize(width: 140, height: 28)

    let panel: NSPanel
    private let view = PillView()

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        // If the panel activates, the frontmost app changes between recording and pasting and the
        // text lands in the wrong window. Every property here exists to prevent that.
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = view
    }

    func show(_ state: PillState) {
        // No attached display means there is nowhere to draw. That is not a degraded pill, it is the
        // absence of a screen, so nothing is invented to stand in for one.
        guard let screen = NSScreen.main?.visibleFrame else { return }
        view.render(state)
        panel.setFrame(Self.placement(caret: Self.caretRect(), screen: screen, size: Self.size), display: true)
        // orderFrontRegardless, never makeKeyAndOrderFront: the latter would activate the panel.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Anchored just below the caret when the focused app exposes one. An app that does not is given
    /// bottom-centre of the active screen rather than no pill at all — the pill must be visible while
    /// the hotkey is held, so this is a designed placement, not a silent fallback.
    static func placement(caret: NSRect?, screen: NSRect, size: NSSize) -> NSRect {
        guard let caret else {
            return NSRect(
                x: screen.midX - size.width / 2,
                y: screen.minY + 80,
                width: size.width,
                height: size.height
            )
        }

        let preferred = NSRect(
            x: caret.midX - size.width / 2,
            y: caret.minY - size.height - 8,
            width: size.width,
            height: size.height
        )
        return clamp(preferred, within: screen)
    }

    private static func clamp(_ rect: NSRect, within screen: NSRect) -> NSRect {
        var placed = rect
        placed.origin.x = min(max(rect.minX, screen.minX), screen.maxX - rect.width)
        placed.origin.y = min(max(rect.minY, screen.minY), screen.maxY - rect.height)
        return placed
    }

    /// The caret in screen coordinates, when the focused element exposes one. Support varies per app
    /// — the same Accessibility variance task 12 is built around — so a nil here is ordinary.
    private static func caretRect() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }

        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let selection = range else { return nil }

        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element as! AXUIElement,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selection,
            &bounds
        ) == .success, let boundsValue = bounds else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
        return flipToScreenCoordinates(rect)
    }

    // The Accessibility API reports top-left origin; AppKit windows use bottom-left.
    private static func flipToScreenCoordinates(_ rect: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        return NSRect(
            x: rect.origin.x,
            y: primary.frame.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
