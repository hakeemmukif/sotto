import AppKit
import Testing
@testable import Sotto

@Suite("The recording pill", .serialized)
@MainActor
struct PillWindowTests {
    // The hard constraint: if the panel ever activates, the frontmost app changes between recording
    // and pasting and the text lands in the wrong window. Every assertion here defends that.
    @Test func thePanelCanNeverTakeFocus() {
        let pill = PillWindow()

        #expect(pill.panel.styleMask.contains(.nonactivatingPanel))
        #expect(pill.panel.canBecomeKey == false)
        #expect(pill.panel.canBecomeMain == false)
        #expect(pill.panel.ignoresMouseEvents)
        #expect(pill.panel.level == .statusBar)
    }

    @Test func showingThePillLeavesTheFrontmostApplicationUnchanged() {
        let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let pill = PillWindow()

        pill.show(.recording(level: 0.4))
        let during = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        pill.hide()

        #expect(during == before)
    }

    @Test func everyPipelineStateIsRenderable() {
        let pill = PillWindow()
        let states: [PillState] = [
            .recording(level: 0.0),
            .recording(level: 1.0),
            .transcribing,
            .cleaning,
            .pastedRaw,
            .secureInput,
        ]

        for state in states {
            pill.show(state)
            #expect(pill.panel.isVisible)
        }
        pill.hide()
        #expect(pill.panel.isVisible == false)
    }

    // No pipeline failure may be invisible — that is task 13's acceptance criterion, enforced here.
    @Test func everyFailureStateReachesTheScreen() {
        #expect(PillState(.secureInputActive) == .secureInput)
        #expect(PillState(.backendUnavailable) == .pastedRaw)
        #expect(PillState(.permissionMissing("Microphone")) == .failed("Microphone"))
        #expect(PillState(.failed("boom")) == .failed("boom"))

        #expect(PillState(.done) == nil)
        #expect(PillState(.cancelled) == nil)
    }

    // Absence renders as absence: a caret-less app gets a defined placement, not a hidden pill.
    @Test func aCaretlessAppStillGetsAVisiblePlacement() {
        let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let size = NSSize(width: 120, height: 36)

        let anchored = PillWindow.placement(caret: NSRect(x: 800, y: 900, width: 2, height: 20), screen: screen, size: size)
        let fallback = PillWindow.placement(caret: nil, screen: screen, size: size)

        #expect(screen.contains(anchored))
        #expect(screen.contains(fallback))
        #expect(anchored != fallback)
        #expect(fallback.midX == screen.midX)
    }

    @Test func thePillNeverLeavesTheScreenNearAnEdge() {
        let screen = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let size = NSSize(width: 120, height: 36)

        for caret in [
            NSRect(x: 2559, y: 1439, width: 2, height: 20),
            NSRect(x: 0, y: 0, width: 2, height: 20),
            NSRect(x: 2559, y: 0, width: 2, height: 20),
        ] {
            let placed = PillWindow.placement(caret: caret, screen: screen, size: size)
            #expect(screen.contains(placed), "pill escaped the screen for caret \(caret)")
        }
    }
}
