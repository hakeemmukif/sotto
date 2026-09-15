import AppKit
import Testing
@testable import Sotto

@Suite("The recording pill", .serialized)
@MainActor
struct PillWindowTests {
    // Live states are the ones a job is still running through; terminal states are outcomes the user
    // may act on. The pill only becomes clickable in the second group.
    private static let live: [PillState] = [
        .recording(level: 0, elapsed: 0),
        .recording(level: 1, elapsed: 12),
        .working(.transcribing),
        .working(.cleaning),
        .working(.pasting),
    ]

    private static let terminal: [PillState] = [
        .pastedRaw,
        .secureInput,
        .permissionMissing("Microphone"),
        .failed(stage: .launch, reason: "the hotkey could not be registered"),
        .failed(stage: .recording, reason: "no input device"),
        .failed(stage: .transcription, reason: "whisper-cli produced an empty transcript"),
        .failed(stage: .cleanup, reason: "the cleanup backend is unreachable"),
        .failed(stage: .insertion, reason: "could not create the synthetic keyboard event"),
    ]

    @Test func everyDictationStateMapsToTheIntendedPill() {
        #expect(PillState(.recording) == .recording(level: 0, elapsed: 0))
        #expect(PillState(.transcribing) == .working(.transcribing))
        #expect(PillState(.cleaning) == .working(.cleaning))
        // The bug this replaces: .inserting shared .cleaning, so the pill said "Cleaning" during the
        // one moment the user is watching for the paste.
        #expect(PillState(.inserting) == .working(.pasting))

        #expect(PillState(.done) == nil)
        #expect(PillState(.cancelled) == nil)
        #expect(PillState(.aborted) == nil)

        #expect(PillState(.secureInputActive) == .secureInput)
        #expect(PillState(.backendUnavailable) == .pastedRaw)
        // Its own case, not a .failed: the remedy for a missing permission is in System Settings, and
        // folding it into .failed destroys the one fact needed to say so.
        #expect(PillState(.permissionMissing("Microphone")) == .permissionMissing("Microphone"))

        for stage in [FailureStage.launch, .recording, .transcription, .cleanup, .insertion] {
            #expect(PillState(.failed(stage: stage, reason: "boom")) == .failed(stage: stage, reason: "boom"))
        }
    }

    // The hard constraint: if the panel ever activates, the frontmost app changes between recording
    // and pasting and the text lands in the wrong window. The four never-activate assertions are the
    // point; only the mouse-events one is allowed to vary, and only once the job is over.
    @Test func thePanelCanNeverTakeFocusInAnyState() {
        let pill = PillWindow()

        for (state, isLive) in Self.live.map({ ($0, true) }) + Self.terminal.map({ ($0, false) }) {
            pill.show(state)

            #expect(pill.panel.styleMask.contains(.nonactivatingPanel), "\(state)")
            #expect(pill.panel.canBecomeKey == false, "\(state)")
            #expect(pill.panel.canBecomeMain == false, "\(state)")
            #expect(pill.panel.level == .statusBar, "\(state)")
            #expect(pill.panel.ignoresMouseEvents == isLive, "\(state)")
        }
        pill.hide()
    }

    // A terminal pill is clickable in a window that can never be key, which is exactly what
    // acceptsFirstMouse exists for. Without it the click is swallowed instead of delivered.
    @Test func theHostingViewTakesTheFirstClickWithoutTheWindowBecomingKey() {
        let pill = PillWindow()
        let host = pill.panel.contentView as? PillHostingView

        #expect(host?.acceptsFirstMouse(for: nil) == true)
        #expect(pill.panel.canBecomeKey == false)
    }

    @Test func showingThePillLeavesTheFrontmostApplicationUnchanged() {
        // Run it for a terminal state too: that is the newly clickable case, so it is the one that
        // could plausibly have reintroduced activation.
        for state in [PillState.recording(level: 0.4, elapsed: 1), .failed(stage: .cleanup, reason: "unreachable")] {
            let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let pill = PillWindow()

            pill.show(state)
            let during = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            pill.hide()

            #expect(during == before, "\(state)")
        }
    }

    @Test func everyPipelineStateIsRenderable() {
        let pill = PillWindow()

        for state in Self.live + Self.terminal {
            pill.show(state)
            #expect(pill.panel.isVisible, "\(state)")
        }
        pill.hide()
        #expect(pill.panel.isVisible == false)
    }

    // No pipeline failure may be invisible — the acceptance criterion this suite has always encoded.
    @Test func everyFailureStateReachesTheScreen() {
        let failures: [DictationState] = [
            .secureInputActive,
            .backendUnavailable,
            .permissionMissing("Microphone"),
            .failed(stage: .launch, reason: "boom"),
            .failed(stage: .recording, reason: "boom"),
            .failed(stage: .transcription, reason: "boom"),
            .failed(stage: .cleanup, reason: "boom"),
            .failed(stage: .insertion, reason: "boom"),
        ]

        for state in failures {
            #expect(PillState(state) != nil, "\(state)")
        }
    }

    @Test func theContentSizesItselfToTheMessageAndStopsAtTheBound() {
        let pill = PillWindow()

        pill.show(.working(.transcribing))
        let short = pill.panel.frame.size
        pill.show(.failed(stage: .cleanup, reason: String(repeating: "e", count: 200)))
        let tall = pill.panel.frame.size
        pill.hide()

        // "Transcribing" is twelve characters and carries neither a reason nor a route, so it is one
        // line and narrower than the bound — proof the pill sizes to content rather than to 360.
        #expect(PillState.working(.transcribing).reasonLine == nil)
        #expect(PillState.working(.transcribing).routeLine == nil)
        #expect(short.width < PillContentView.maxWidth)

        #expect(tall.width <= PillContentView.maxWidth)
        #expect(tall.height > short.height)
        // Headline, reason and route are one line each, never a wrapped paragraph: three lines of
        // text plus one set of padding is strictly less than three whole one-line pills.
        #expect(tall.height < short.height * 3)
    }

    @Test func anOverlongReasonIsCutForDisplayAndPointsAtTheLog() {
        let whole = String(repeating: "e", count: 400)
        let state = PillState.failed(stage: .transcription, reason: whole)

        #expect(state.reasonLine?.count == PillState.reasonDisplayLimit + 1)
        #expect(state.reasonLine?.hasSuffix("…") == true)
        #expect(state.routeLine == "Full text in ~/Library/Logs/Sotto.log.")
        // Only the rendering is bounded: the state still carries every character the pipeline saw.
        #expect(state == .failed(stage: .transcription, reason: whole))
    }

    @Test func everyDismissDelayMatchesHowLongItsStateTakesToRead() {
        for state in Self.live {
            #expect(PillState.dismissDelay(for: state) == nil, "\(state)")
        }

        #expect(PillState.dismissDelay(for: .pastedRaw) == 4)
        #expect(PillState.dismissDelay(for: .secureInput) == 4)

        #expect(PillState.dismissDelay(for: .permissionMissing("Microphone")) == 8)
        for stage in [FailureStage.launch, .recording, .transcription, .cleanup, .insertion] {
            #expect(PillState.dismissDelay(for: .failed(stage: stage, reason: "boom")) == 8, "\(stage)")
        }
    }

    @Test func aTerminalPillDismissesItselfAndANewerJobCancelsThePendingDismissal() {
        var pending: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []
        let pill = PillWindow(schedule: { delay, body in pending.append((delay, body)) })

        pill.show(.pastedRaw)
        #expect(pill.panel.isVisible)
        #expect(pending.count == 1)
        #expect(pending[0].delay == 4)

        // A newer state for a newer job replaces the old one; its dismissal must not take the new
        // pill down with it.
        pill.show(.working(.transcribing))
        pending[0].fire()
        #expect(pill.panel.isVisible)
        #expect(pending.count == 1)

        pill.show(.failed(stage: .cleanup, reason: "the cleanup backend is unreachable"))
        #expect(pending.count == 2)
        #expect(pending[1].delay == 8)
        pending[1].fire()
        #expect(pill.panel.isVisible == false)
    }

    @Test func everyRouteLeadsWhereTheRemedyIs() {
        // Cleanup is configured inside Sotto, so a cleanup failure and a raw paste both land there.
        #expect(PillState.route(for: .failed(stage: .cleanup, reason: "x")) == .settings)
        #expect(PillState.route(for: .pastedRaw) == .settings)

        // The other stages leave a transcript worth recovering, and that lives in History.
        #expect(PillState.route(for: .failed(stage: .launch, reason: "x")) == .history)
        #expect(PillState.route(for: .failed(stage: .recording, reason: "x")) == .history)
        #expect(PillState.route(for: .failed(stage: .transcription, reason: "x")) == .history)
        #expect(PillState.route(for: .failed(stage: .insertion, reason: "x")) == .history)

        #expect(PillState.route(for: .permissionMissing("Microphone")) == .systemSettings("Microphone"))

        // Secure input is a property of the app the user is in, not of Sotto: there is nothing to open.
        #expect(PillState.route(for: .secureInput) == nil)

        for state in Self.live {
            #expect(PillState.route(for: state) == nil, "\(state)")
        }
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

        // Both a one-line pill and the tallest the pill can get: the clamp has to hold for the
        // three-line failure pill, which is the one that reaches furthest below the caret.
        for size in [NSSize(width: 120, height: 36), NSSize(width: 360, height: 72)] {
            for caret in [
                NSRect(x: 2559, y: 1439, width: 2, height: 20),
                NSRect(x: 0, y: 0, width: 2, height: 20),
                NSRect(x: 2559, y: 0, width: 2, height: 20),
            ] {
                let placed = PillWindow.placement(caret: caret, screen: screen, size: size)
                #expect(screen.contains(placed), "pill escaped the screen for caret \(caret) at \(size)")
            }
        }
    }
}
