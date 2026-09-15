import AppKit

enum PillState: Equatable {
    case recording(level: Float)
    case transcribing
    case cleaning
    case pastedRaw
    case secureInput
    case failed(String)

    /// The pipeline emits per-job truth; deciding what the user sees is this layer's job. `nil` means
    /// the pill hides. Every error state maps to something visible — the acceptance criterion is that
    /// no failure anywhere results in nothing happening on screen.
    init?(_ state: DictationState) {
        switch state {
        case .recording: self = .recording(level: 0)
        case .transcribing: self = .transcribing
        case .cleaning, .inserting: self = .cleaning
        case .done, .cancelled, .aborted: return nil
        case .secureInputActive: self = .secureInput
        case .backendUnavailable: self = .pastedRaw
        case let .permissionMissing(what): self = .failed(what)
        case let .failed(_, reason): self = .failed(reason)
        }
    }
}

// Status never travels on colour alone: every state carries a label, and the two failure states say
// what went wrong rather than relying on amber and red being noticed.
extension PillState {
    var label: String {
        switch self {
        case .recording: "Listening"
        case .transcribing: "Transcribing"
        case .cleaning: "Cleaning"
        case .pastedRaw: "Pasted raw — cleanup unavailable"
        case .secureInput: "Secure input — cannot insert"
        case let .failed(reason): reason
        }
    }

    var tint: NSColor {
        switch self {
        case .recording: .systemTeal
        case .transcribing, .cleaning: .secondaryLabelColor
        case .pastedRaw: .systemOrange
        case .secureInput, .failed: .systemRed
        }
    }
}

final class PillView: NSView {
    private var state: PillState = .transcribing

    func render(_ state: PillState) {
        self.state = state
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 3
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let dot = NSRect(x: 12, y: bounds.midY - 4, width: 8, height: 8)
        state.tint.setFill()
        NSBezierPath(ovalIn: dot).fill()

        if case let .recording(level) = state {
            drawMeter(level: level, after: dot)
            return
        }

        let text = state.label as NSString
        text.draw(
            at: NSPoint(x: dot.maxX + 8, y: bounds.midY - 7),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
        )
    }

    private func drawMeter(level: Float, after dot: NSRect) {
        let bars = 5
        let width: CGFloat = 3
        let gap: CGFloat = 3
        NSColor.systemTeal.setFill()

        for bar in 0..<bars {
            let reach = Float(bar + 1) / Float(bars)
            let height = 4 + CGFloat(min(level / reach, 1.0)) * 12
            let rect = NSRect(
                x: dot.maxX + 8 + CGFloat(bar) * (width + gap),
                y: bounds.midY - height / 2,
                width: width,
                height: height
            )
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
