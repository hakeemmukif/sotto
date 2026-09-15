import AppKit
import SwiftUI

/// The Windows 95 "Chicago" visual vocabulary: colors, fonts, and beveled borders.
/// Design-system pieces only — no app screens, no state.
enum Chicago {
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    static let face = rgb(192, 192, 192)        // #c0c0c0
    static let bevelLight = rgb(255, 255, 255)  // #ffffff
    static let bevelMid = rgb(223, 223, 223)    // #dfdfdf
    static let bevelDark = rgb(128, 128, 128)   // #808080
    static let bevelBlack = rgb(0, 0, 0)        // #000000
    static let stripe = rgb(184, 184, 184)      // #b8b8b8
    static let gridline = rgb(170, 170, 170)    // #aaaaaa
    static let selection = rgb(0, 0, 128)       // #000080
    static let titleBarEnd = rgb(16, 132, 208)  // #1084d0
    static let muted = rgb(64, 64, 64)          // #404040
    static let selectedMuted = rgb(195, 195, 234) // #c3c3ea — muted text on a selected row
    static let warning = rgb(138, 43, 0)        // #8a2b00

    static let faceNSColor = NSColor(red: 192 / 255, green: 192 / 255, blue: 192 / 255, alpha: 1)

    static func pixel(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }

    // Verdana first, then Tahoma: the approved prototype measures in Verdana, which is wider, so
    // preferring Tahoma would shift every text-driven width away from the design.
    static func ui(_ size: CGFloat) -> Font {
        for name in ["Verdana", "Tahoma"] where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size)
    }

    static func body(_ size: CGFloat) -> Font {
        .system(size: size)
    }
}

/// Four 1pt lines drawn inside the view's bounds. Drawn in a `Canvas` snapped to whole device
/// pixels: a text-driven height like 20.5 puts a plain `Rectangle` on a half-pixel boundary, where
/// antialiasing smears one line across two rows and the bevel reads as a heavy grey-black band.
struct ChicagoBevel: ViewModifier {
    let raised: Bool
    let thin: Bool

    @Environment(\.displayScale) private var scale

    func body(content: Content) -> some View {
        content.overlay(
            Canvas { context, size in
                let unit: CGFloat = 1
                let width = (size.width * scale).rounded(.down) / scale
                let height = (size.height * scale).rounded(.down) / scale

                func line(_ color: Color, _ rect: CGRect) {
                    context.fill(Path(rect), with: .color(color))
                }

                let outerNear = raised ? Chicago.bevelLight : Chicago.bevelDark
                let outerFar = raised ? Chicago.bevelBlack : Chicago.bevelLight
                line(outerNear, CGRect(x: 0, y: 0, width: width, height: unit))
                line(outerNear, CGRect(x: 0, y: 0, width: unit, height: height))
                line(outerFar, CGRect(x: 0, y: height - unit, width: width, height: unit))
                line(outerFar, CGRect(x: width - unit, y: 0, width: unit, height: height))

                guard !thin else { return }

                let innerNear = raised ? Chicago.bevelMid : Chicago.bevelBlack
                let innerFar = raised ? Chicago.bevelDark : Chicago.bevelMid
                line(innerNear, CGRect(x: unit, y: unit, width: width - 2 * unit, height: unit))
                line(innerNear, CGRect(x: unit, y: unit, width: unit, height: height - 2 * unit))
                line(innerFar, CGRect(x: unit, y: height - 2 * unit, width: width - 2 * unit, height: unit))
                line(innerFar, CGRect(x: width - 2 * unit, y: unit, width: unit, height: height - 2 * unit))
            }
            .allowsHitTesting(false)
        )
    }
}

extension View {
    func chicagoRaised() -> some View {
        modifier(ChicagoBevel(raised: true, thin: false))
    }

    func chicagoSunken() -> some View {
        modifier(ChicagoBevel(raised: false, thin: false))
    }

    func chicagoThinRaised() -> some View {
        modifier(ChicagoBevel(raised: true, thin: true))
    }

    func chicagoThinSunken() -> some View {
        modifier(ChicagoBevel(raised: false, thin: true))
    }
}

struct ChicagoButtonStyle: ButtonStyle {
    // `pressed` is latched-on state, as in a toggled toolbar button, separate from the
    // momentary press SwiftUI already reports via configuration.isPressed.
    var pressed = false
    var fontSize: CGFloat = 11
    var horizontal: CGFloat = 11
    var height: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Chicago.ui(fontSize))
            .foregroundStyle(.black)
            .padding(.horizontal, horizontal)
            .frame(height: height)
            .background(pressed ? Chicago.stripe : Chicago.face)
            .modifier(ChicagoBevel(raised: !(configuration.isPressed || pressed), thin: false))
    }
}

struct ChicagoTitleBar: View {
    let title: String
    var onMinimize: (() -> Void)?
    var onZoom: (() -> Void)?
    var onClose: (() -> Void)?

    /// Nested inside the window's own corner radius minus the 3pt Chicago frame, so the blue
    /// follows the macOS curve instead of poking square corners through it.
    private static let cornerRadius: CGFloat = 7

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            Text(title)
                .font(Chicago.ui(12))
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 0, x: 1, y: 1)
                .padding(.leading, 4)

            Spacer(minLength: 0)

            button(action: onMinimize) {
                Rectangle().fill(.black)
                    .frame(width: 7, height: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 3)
                    .padding(.bottom, 3)
            }
            button(action: onZoom) {
                Rectangle()
                    .stroke(.black, lineWidth: 1)
                    .overlay(alignment: .top) { Rectangle().fill(.black).frame(height: 2) }
                    .frame(width: 10, height: 9)
            }
            button(action: onClose) {
                Text("×").font(.system(size: 12, weight: .medium)).foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 23)
        .background(
            LinearGradient(colors: [Chicago.selection, Chicago.titleBarEnd], startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: Self.cornerRadius, topTrailingRadius: Self.cornerRadius
            )
        )
    }

    // A button with no action is drawn but dead: an empty raised square reads as a rendering bug,
    // and a window that cannot zoom should still look like every other Windows 95 window.
    @ViewBuilder
    private func button(action: (() -> Void)?, @ViewBuilder glyph: () -> some View) -> some View {
        if let action {
            Button(action: action) { glyph().frame(width: 17, height: 15) }
                .buttonStyle(ChicagoButtonStyle(horizontal: 0, height: 15))
        } else {
            glyph()
                .frame(width: 17, height: 15)
                .background(Chicago.face)
                .chicagoRaised()
        }
    }
}

/// A Windows 95 tab strip. The selected tab is taller and sits flush with the panel below it, the
/// others drop by the difference so the strip reads as one row of folder tabs.
struct ChicagoTabBar: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                Button { selection = index } label: {
                    Text(title)
                        .font(Chicago.ui(11))
                        .fontWeight(selection == index ? .bold : .regular)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: selection == index ? 23 : 20)
                        .background(selection == index ? Chicago.face : Chicago.stripe)
                        .modifier(ChicagoBevel(raised: true, thin: true))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 23, alignment: .bottom)
    }
}
