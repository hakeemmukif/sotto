import AppKit
import SwiftUI

/// The history window, opened from the menu bar or by relaunching Sotto from Spotlight.
///
/// Sotto is `LSUIElement`, so it owns no window by default and never becomes the active app on its
/// own. Both of those have to be undone by hand here, or the window appears behind whatever the
/// user was typing into and never takes key focus.
@MainActor
final class HistoryWindowController: NSWindowController {
    private let viewModel: HistoryViewModel

    init(store: HistoryStore, hotkeyLabel: String?, cleaner: Cleaner?) {
        let viewModel = HistoryViewModel(store: store)
        self.viewModel = viewModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // A `.titled` window stays opaque, so a clear background composites as black in the ring
        // between the content's corner radius and the frame's. Paint the face and let the system
        // round and shadow the window.
        window.backgroundColor = Chicago.faceNSColor
        // Windows 95 had no dark mode. Without this the system appearance wins inside the controls
        // and TextEditor, TextField and the filter menu draw white text on the white Chicago field.
        window.appearance = NSAppearance(named: .aqua)
        // The window draws its own Chicago title bar, so the traffic lights would sit on top of it.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.center()
        window.setFrameAutosaveName("SottoHistory")

        super.init(window: window)

        window.contentView = NSHostingView(
            rootView: HistoryView(
                viewModel: viewModel,
                promptModel: PromptPlaygroundModel(cleaner: cleaner),
                hotkeyLabel: hotkeyLabel,
                onMinimize: { [weak window] in window?.miniaturize(nil) },
                onZoom: { [weak window] in window?.zoom(nil) },
                onClose: { [weak window] in window?.close() }
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show() {
        viewModel.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HistoryView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @ObservedObject var promptModel: PromptPlaygroundModel
    let hotkeyLabel: String?
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onClose: () -> Void

    @State private var tab = 0

    private static let controlHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            ChicagoTitleBar(title: "Sotto", onMinimize: onMinimize, onZoom: onZoom, onClose: onClose)
            statStrip

            ChicagoTabBar(titles: ["History", "Prompt"], selection: $tab)
                .padding(.horizontal, 6)
                .padding(.top, 6)

            if tab == 0 {
                toolbar
                listView
            } else {
                PromptPlaygroundView(model: promptModel)
                    .padding(.top, 6)
            }

            statusBar
        }
        .padding(3)
        .background(Chicago.face)
        .chicagoRaised()
        // `.fullSizeContentView` publishes the title-bar height as a top safe-area inset, which
        // would push the Chicago title bar down the window and leave bare face colour above it.
        .ignoresSafeArea()
    }

    // MARK: - Stat strip

    private var statStrip: some View {
        HStack(spacing: 0) {
            statPane("Words: ", "\(viewModel.totalWords.formatted())")
            statPane("Avg: ", "\(viewModel.averageWPM)", suffix: " wpm")
            statPane("Streak: ", "\(viewModel.streakDays)", suffix: " days")
            Color.clear.frame(maxWidth: .infinity).frame(height: 21).chicagoThinSunken()
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    private func statPane(_ label: String, _ value: String, suffix: String = "") -> some View {
        (Text(label).font(Chicago.ui(11))
            + Text(value).font(Chicago.ui(11).weight(.semibold)).monospacedDigit()
            + Text(suffix).font(Chicago.ui(11)))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .frame(height: 21)
            .chicagoThinSunken()
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 5) {
            TextField("Search transcripts", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(Chicago.body(12.5))
                .padding(.horizontal, 7)
                .frame(height: Self.controlHeight)
                .background(Color.white)
                .chicagoSunken()

            appMenu

            HStack(spacing: 3) {
                Button("Cleaned") { viewModel.showRaw = false }
                    .buttonStyle(ChicagoButtonStyle(pressed: !viewModel.showRaw))
                Button("Raw") { viewModel.showRaw = true }
                    .buttonStyle(ChicagoButtonStyle(pressed: viewModel.showRaw))
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    // A Menu rather than a Picker: NSPopUpButton ignores both `.font` and `.frame(height:)`, so a
    // Picker cannot be held to the toolbar's control height or given the Chicago face.
    private var appMenu: some View {
        Menu {
            Button("All apps") { viewModel.appFilter = nil }
            ForEach(viewModel.availableApps, id: \.bundleID) { app in
                Button(app.name) { viewModel.appFilter = app.bundleID }
            }
        } label: {
            HStack(spacing: 0) {
                Text(selectedAppName).font(Chicago.ui(11)).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 6))
            }
            .foregroundStyle(.black)
            .padding(.leading, 7)
            .padding(.trailing, 6)
            .frame(width: 130, height: Self.controlHeight)
            .background(Color.white)
            .chicagoSunken()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var selectedAppName: String {
        viewModel.availableApps.first { $0.bundleID == viewModel.appFilter }?.name ?? "All apps"
    }

    // MARK: - List

    private var listView: some View {
        VStack(spacing: 0) {
            columnHeaders
            ScrollView {
                if viewModel.groups.isEmpty {
                    Text(viewModel.totalCount == 0 ? "No dictations yet." : "No dictations match.")
                        .font(Chicago.ui(11))
                        .foregroundStyle(Chicago.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                        .padding(.horizontal, 10)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.groups) { day in
                            Text(day.label)
                                .font(Chicago.pixel(8))
                                .tracking(0.7)
                                .foregroundStyle(Chicago.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.top, 6)
                                .padding(.bottom, 4)
                                .background(Chicago.stripe)

                            ForEach(Array(day.records.enumerated()), id: \.element.id) { index, record in
                                HistoryRow(
                                    record: record,
                                    text: viewModel.displayText(for: record),
                                    isSelected: viewModel.selectedID == record.id,
                                    isStriped: index.isMultiple(of: 2) == false,
                                    appName: viewModel.appName(for: record),
                                    onSelect: {
                                        viewModel.selectedID = viewModel.selectedID == record.id ? nil : record.id
                                    },
                                    onCopy: { viewModel.copyToPasteboard(record.id) },
                                    onDelete: { viewModel.delete(record.id) }
                                )
                            }
                        }
                    }
                }
            }
            .background(Chicago.face)
        }
        .padding(2)
        .chicagoSunken()
        .padding(.horizontal, 6)
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(Chicago.ui(10.5))
            .foregroundStyle(Chicago.muted)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
            .background(Chicago.face)
            .modifier(ChicagoBevel(raised: true, thin: true))
    }

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Button {
                viewModel.newestFirst.toggle()
            } label: {
                columnHeader("Time \(viewModel.newestFirst ? "▼" : "▲")")
            }
            .buttonStyle(.plain)
            .frame(width: 60)

            columnHeader("Transcript")
            columnHeader("Details").frame(width: 132)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 4) {
            statusPane(countText, width: 150)
            statusPane(hotkeyText, width: 190)
            statusPane("~/Library/Application Support/Sotto/history.jsonl", width: nil)
        }
        .font(Chicago.ui(10))
        .foregroundStyle(Chicago.muted)
        .padding(6)
    }

    @ViewBuilder
    private func statusPane(_ text: String, width: CGFloat?) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .frame(height: 19)
            .chicagoThinSunken()
    }

    private var countText: String {
        viewModel.shownCount == viewModel.totalCount
            ? "\(viewModel.totalCount) dictations"
            : "\(viewModel.shownCount) of \(viewModel.totalCount) shown"
    }

    // No hotkey means settings never loaded, so there is no key to name. Say that rather than
    // printing a hold instruction for a key that does nothing.
    private var hotkeyText: String {
        guard let hotkeyLabel else { return "Dictation not running" }
        return "Hold \(Self.symbols(for: hotkeyLabel)) to speak"
    }

    private static func symbols(for hotkey: String) -> String {
        let glyphs = ["ctrl": "⌃", "control": "⌃", "opt": "⌥", "option": "⌥", "alt": "⌥",
                      "cmd": "⌘", "command": "⌘", "shift": "⇧"]
        return hotkey
            .split(separator: "+")
            .map { glyphs[$0.trimmingCharacters(in: .whitespaces).lowercased()] ?? String($0) }
            .joined()
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    let text: String
    let isSelected: Bool
    let isStriped: Bool
    let appName: String
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text(record.timestamp.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                .font(Chicago.pixel(9))
                .foregroundStyle(isSelected ? Chicago.selectedMuted : Chicago.muted)
                .frame(width: 42, alignment: .leading)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(Chicago.body(13.5))
                    .lineSpacing(3.5)
                    .foregroundStyle(isSelected ? .white : .black)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Text(appName.uppercased())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(isSelected ? Chicago.selection.opacity(0.6) : Chicago.stripe)
                        .chicagoThinRaised()
                    Text("\(record.wordCount) WORDS")
                    Text(String(format: "%.1fS", Double(record.durationMs) / 1000))
                    Text("\(wpm) WPM")
                }
                .font(Chicago.pixel(8))
                .foregroundStyle(isSelected ? Chicago.selectedMuted : Chicago.muted)
            }

            if isHovering || isSelected {
                HStack(spacing: 3) {
                    Button("Copy", action: onCopy)
                    Button("Delete", action: onDelete)
                }
                .buttonStyle(ChicagoButtonStyle(fontSize: 10, horizontal: 8, height: 19))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .bottom) { Chicago.gridline.frame(height: 1) }
        .overlay {
            if isSelected {
                Rectangle()
                    .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1, dash: [1, 1]))
                    .padding(3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var wpm: Int {
        let minutes = Double(record.durationMs) / 60000
        return minutes > 0 ? Int((Double(record.wordCount) / minutes).rounded()) : 0
    }

    private var background: Color {
        if isSelected { return Chicago.selection }
        if isHovering { return Chicago.selection.opacity(0.14) }
        return isStriped ? Chicago.stripe : Chicago.face
    }
}
