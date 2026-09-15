import AppKit
import SwiftUI

/// Where a click on a terminal pill sends the user. Opening these is task 19; this task only decides
/// the destination, so that the pill stops being a dead end the moment routing lands.
enum PillRoute: Equatable, Sendable {
    case settings
    case history
    case systemSettings(String)
}

enum PillState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case transcribing, cleaning, pasting
    }

    case recording(level: Float, elapsed: TimeInterval)
    case working(Phase)
    case pastedRaw
    case secureInput
    case permissionMissing(String)
    case failed(stage: FailureStage, reason: String)

    /// The pipeline emits per-job truth; deciding what the user sees is this layer's job. `nil` means
    /// the pill hides. Every error state maps to something visible — the acceptance criterion is that
    /// no failure anywhere results in nothing happening on screen.
    init?(_ state: DictationState) {
        switch state {
        // Zeroes because `DictationState.recording` carries no audio. Task 14 constructs this case
        // directly from the tap, so it changes the producer rather than this type.
        case .recording: self = .recording(level: 0, elapsed: 0)
        case .transcribing: self = .working(.transcribing)
        case .cleaning: self = .working(.cleaning)
        case .inserting: self = .working(.pasting)
        case .done, .cancelled, .aborted: return nil
        case .secureInputActive: self = .secureInput
        case .backendUnavailable: self = .pastedRaw
        // Its own case rather than a `.failed`: a missing microphone permission is granted in System
        // Settings, not in Sotto's settings panel, and only the distinct case can say so.
        case let .permissionMissing(what): self = .permissionMissing(what)
        case let .failed(stage, reason): self = .failed(stage: stage, reason: reason)
        }
    }
}

extension PillState {
    /// Whether a job is still running through this state. A live pill stays on screen until the next
    /// state replaces it and swallows no clicks; a terminal one is an outcome the user may act on.
    var isLive: Bool {
        switch self {
        case .recording, .working: true
        case .pastedRaw, .secureInput, .permissionMissing, .failed: false
        }
    }

    /// How long a terminal pill stays before it hides itself. Before this, a failure stayed on screen
    /// until the next dictation replaced it and could not be dismissed by hand either.
    static func dismissDelay(for state: PillState) -> TimeInterval? {
        switch state {
        case .recording, .working: nil
        // Four seconds to notice an outcome that still produced text; eight to read one that did not,
        // because a failure spends those seconds on three lines rather than one.
        case .pastedRaw, .secureInput: 4
        case .permissionMissing, .failed: 8
        }
    }

    /// Where the remedy for this state lives.
    static func route(for state: PillState) -> PillRoute? {
        switch state {
        case .recording, .working: nil
        // Cleanup is configured inside Sotto, so both of its outcomes land in the settings panel.
        case .pastedRaw: .settings
        // Secure input is a property of the app the user is typing into, not of Sotto. There is
        // nothing for a click to open, so the pill offers no route rather than inventing one.
        case .secureInput: nil
        case let .permissionMissing(what): .systemSettings(what)
        case let .failed(stage, _):
            switch stage {
            case .cleanup: .settings
            // The other stages leave a transcript worth recovering, and that lives in History.
            case .launch, .recording, .transcription, .insertion: .history
            }
        }
    }
}

// The pill is the only surface the user sees on every dictation, so a message state says three
// things: what happened, why, and what to do about it. Status never travels on colour alone.
extension PillState {
    /// Past this the rendered reason is cut and the route line points at the log instead. The state
    /// keeps the whole string: a reason is diagnostic data, and bounding the pill must not bound it.
    static let reasonDisplayLimit = 200

    /// What happened and what it cost.
    var headline: String {
        switch self {
        case .recording: "Listening"
        case let .working(phase):
            switch phase {
            case .transcribing: "Transcribing"
            case .cleaning: "Cleaning"
            case .pasting: "Pasting"
            }
        case .pastedRaw: "Pasted raw — no cleanup."
        case .secureInput: "Secure input — cannot paste here."
        case let .permissionMissing(what): "\(what) permission missing."
        case let .failed(stage, _):
            switch stage {
            case .launch: "Sotto could not start — dictation is off."
            case .recording: "Recording failed — nothing pasted."
            case .transcription: "Transcription failed — nothing pasted."
            case .cleanup: "Cleanup failed — nothing pasted."
            case .insertion: "Insertion failed — nothing pasted."
            }
        }
    }

    /// Why, in the error's own words. The error types conform to `CustomStringConvertible`, so this
    /// is prose rather than the synthesised enum description `"\(error)"` used to produce.
    var reasonLine: String? {
        switch self {
        case .recording, .working, .pastedRaw, .secureInput, .permissionMissing: nil
        case let .failed(_, reason):
            reason.count > Self.reasonDisplayLimit
                ? String(reason.prefix(Self.reasonDisplayLimit)) + "…"
                : reason
        }
    }

    /// What to do about it.
    var routeLine: String? {
        // A cut reason is unreadable in place, so the line spends itself saying where the whole one
        // is instead of offering a destination that would not show it either.
        if case let .failed(_, reason) = self, reason.count > Self.reasonDisplayLimit {
            return "Full text in ~/Library/Logs/Sotto.log."
        }
        switch Self.route(for: self) {
        case .none: return nil
        case .settings: return "Click to open Settings."
        case .history: return "Click to open History."
        case let .systemSettings(what): return "Click to open System Settings ▸ \(what)."
        }
    }
}

/// The pill body. Deliberately neutral — plain colours, system font, a plain bar — because task 20
/// replaces this body with the Chicago skin and can only stay a body swap if nothing structural
/// lives in the styling.
struct PillContentView: View {
    /// Wider than this and the pill stops reading as a status indicator and starts reading as a
    /// dialog. Every line is held to one line, so the height is three lines at worst and the panel's
    /// `fittingSize` is correct without a wrapping pass.
    static let maxWidth: CGFloat = 360

    let state: PillState

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(state.headline)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let reason = state.reasonLine {
                    detail(reason)
                }
                if let route = state.routeLine {
                    detail(route)
                }
            }
            if case let .recording(level, elapsed) = state {
                LevelBar(level: level)
                Text(Self.clock(elapsed))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        )
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private static func clock(_ elapsed: TimeInterval) -> String {
        let seconds = Int(elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A plain bar filled in proportion to the level. Task 14 makes `level` move; until then it is zero
/// and the bar reads empty, which is the truth about the meter today.
private struct LevelBar: View {
    let level: Float

    var body: some View {
        let track: CGFloat = 40
        Capsule()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: track, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: track * CGFloat(min(max(level, 0), 1)), height: 4)
            }
    }
}
