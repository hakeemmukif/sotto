import AppKit
import ApplicationServices
import SwiftUI

/// Runs `body` after `delay`. Injected so a test can fire a dismissal without waiting on a clock.
typealias PillScheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

/// Hosts the pill body and takes the click in a terminal state.
///
/// `acceptsFirstMouse` is the part that matters: the panel can never become key, and AppKit delivers
/// a click to a non-key window only when the view under it asks for the first mouse. Returning true
/// does not activate anything — the panel is `.nonactivatingPanel`, so the click reaches this view
/// while the frontmost application stays exactly where it was.
final class PillHostingView: NSHostingView<PillContentView> {
    var onClick: @MainActor () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Not forwarded to super: the body carries no controls, so SwiftUI has no gesture to lose, and
    // keeping the click at the AppKit level keeps it out of the responder chain entirely.
    override func mouseDown(with event: NSEvent) { onClick() }

    required init(rootView: PillContentView) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

@MainActor
final class PillWindow {
    let panel: NSPanel
    /// Where a click goes once the pill has hidden itself. Task 19 supplies the real routing.
    var onActivate: (PillRoute) -> Void = { _ in }

    private let host: PillHostingView
    private let schedule: PillScheduler
    private var shown: PillState?
    /// A newer state belongs to a newer job, and the older job's pending dismissal must not take the
    /// newer pill down with it.
    private var job = 0

    init(schedule: @escaping PillScheduler = PillWindow.afterDelay) {
        self.schedule = schedule
        host = PillHostingView(rootView: PillContentView(state: .working(.transcribing)))
        // The pill is sized to its message, never to a fixed width: a fixed 140 pt cut every message
        // longer than about eighteen characters, which is most of them. `.intrinsicContentSize` and
        // not `.preferredContentSize` — measured 2026-09-16, the latter leaves an NSHostingView's
        // `fittingSize` at zero, which frames the panel 0×0 and shows nothing at all.
        host.sizingOptions = .intrinsicContentSize

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
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
        // The pill floats over whatever app the user is typing into, so its contrast cannot be left
        // to their theme; task 20's skin is light-only for the same reason the history window is.
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentView = host

        host.onClick = { [weak self] in self?.activate() }
    }

    func show(_ state: PillState) {
        // No attached display means there is nowhere to draw. That is not a degraded pill, it is the
        // absence of a screen, so nothing is invented to stand in for one.
        guard let mainFrame = NSScreen.main?.visibleFrame else { return }
        shown = state
        host.rootView = PillContentView(state: state)
        // Clickable only once the job is over. While the job is live a paste is still pending, and
        // the pill is the one window that must never come between the caret and that paste.
        panel.ignoresMouseEvents = state.isLive

        let caret = Self.caretRect()
        // NSScreen.main is not reliably the caret's display for an LSUIElement app with no key window,
        // so the caret's own screen is picked explicitly rather than assumed.
        let screen = Self.screen(containing: caret, in: NSScreen.screens.map(\.visibleFrame), fallback: mainFrame)
        panel.setFrame(
            Self.placement(caret: caret, windowRect: Self.focusedWindowRect(), screen: screen, size: host.fittingSize),
            display: true
        )
        // orderFrontRegardless, never makeKeyAndOrderFront: the latter would activate the panel.
        panel.orderFrontRegardless()

        job += 1
        let current = job
        guard let delay = PillState.dismissDelay(for: state) else { return }
        schedule(delay) { [weak self] in
            guard let self, self.job == current else { return }
            self.hide()
        }
    }

    func hide() {
        shown = nil
        panel.orderOut(nil)
    }

    private func activate() {
        guard let state = shown else { return }
        hide()
        guard let route = PillState.route(for: state) else { return }
        onActivate(route)
    }

    /// Show and hide are abrupt by design: a fade would keep a stale failure on screen while the next
    /// dictation's pill is already being placed.
    static func afterDelay(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            body()
        }
    }

    /// Which anchor a placement is built around. Caret beats the focused window's bottom-centre beats
    /// the screen's bottom-centre — each tier is reached only because accessibility couldn't supply
    /// the one before it, not because it was preferred.
    enum PlacementAnchor: Equatable {
        case caret(NSRect)
        case focusedWindow(NSRect)
        case screen(NSRect)
    }

    static func placementAnchor(caret: NSRect?, windowRect: NSRect?, screen: NSRect) -> PlacementAnchor {
        if let caret { return .caret(caret) }
        if let windowRect { return .focusedWindow(windowRect) }
        return .screen(screen)
    }

    /// Anchored just below the caret when the focused app exposes one. When accessibility can't supply
    /// a caret — support for kAXBoundsForRangeParameterizedAttribute varies per app, so this is
    /// ordinary — the focused window's bottom-centre stands in, and when there is no focused window
    /// either, the screen's bottom-centre, 80 pt up. All three are designed placements: the pill must
    /// be visible while the hotkey is held, never simply absent.
    static func placement(caret: NSRect?, windowRect: NSRect?, screen: NSRect, size: NSSize) -> NSRect {
        switch placementAnchor(caret: caret, windowRect: windowRect, screen: screen) {
        case .screen(let screen):
            return bottomCentre(of: screen, size: size)

        case .focusedWindow(let window):
            return clamp(bottomCentre(of: window, size: size), within: screen)

        case .caret(let caret):
            let below = NSRect(
                x: caret.midX - size.width / 2,
                y: caret.minY - size.height - 8,
                width: size.width,
                height: size.height
            )
            if below.minY >= screen.minY {
                return clamp(below, within: screen)
            }

            // Below would run under the line being typed near the bottom edge — now that a failure
            // pill can be three lines tall this happens well before the caret reaches the edge itself.
            // Flip above the caret instead; only clamp the original position if neither fits.
            let above = NSRect(
                x: caret.midX - size.width / 2,
                y: caret.maxY + 8,
                width: size.width,
                height: size.height
            )
            if above.maxY <= screen.maxY {
                return clamp(above, within: screen)
            }

            return clamp(below, within: screen)
        }
    }

    private static func bottomCentre(of rect: NSRect, size: NSSize) -> NSRect {
        NSRect(x: rect.midX - size.width / 2, y: rect.minY + 80, width: size.width, height: size.height)
    }

    private static func clamp(_ rect: NSRect, within screen: NSRect) -> NSRect {
        var placed = rect
        placed.origin.x = min(max(rect.minX, screen.minX), screen.maxX - rect.width)
        placed.origin.y = min(max(rect.minY, screen.minY), screen.maxY - rect.height)
        return placed
    }

    /// Picks the screen an anchor actually sits on: the one whose frame contains its centre, else the
    /// one with the largest intersection, else the fallback. NSScreen.main is not reliably the display
    /// an AX-reported anchor is on for an LSUIElement app with no key window, so without this a caret
    /// on a second monitor could be clamped onto the first. Screens are a parameter so this is testable
    /// without a second display.
    static func screen(containing anchor: NSRect?, in screens: [NSRect], fallback: NSRect) -> NSRect {
        guard let anchor else { return fallback }

        if let containing = screens.first(where: { $0.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) {
            return containing
        }

        if let overlapping = screens.max(by: { area(of: $0.intersection(anchor)) < area(of: $1.intersection(anchor)) }),
           area(of: overlapping.intersection(anchor)) > 0 {
            return overlapping
        }

        return fallback
    }

    private static func area(of rect: NSRect) -> CGFloat { rect.width * rect.height }

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

    /// The focused window's frame in screen coordinates, when the focused application exposes one.
    /// This is the middle placement tier, reached only once the caret itself came back nil.
    private static func focusedWindowRect() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        var app: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &app) == .success,
              let application = app else { return nil }

        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application as! AXUIElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let focusedWindow = window else { return nil }

        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              let position = positionValue else { return nil }

        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let windowSize = sizeValue else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(windowSize as! AXValue, .cgSize, &size) else { return nil }

        return flipToScreenCoordinates(CGRect(origin: origin, size: size))
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
