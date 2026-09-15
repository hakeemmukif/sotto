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
        guard let screen = NSScreen.main?.visibleFrame else { return }
        shown = state
        host.rootView = PillContentView(state: state)
        // Clickable only once the job is over. While the job is live a paste is still pending, and
        // the pill is the one window that must never come between the caret and that paste.
        panel.ignoresMouseEvents = state.isLive
        panel.setFrame(
            Self.placement(caret: Self.caretRect(), screen: screen, size: host.fittingSize),
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
