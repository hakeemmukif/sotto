import SwiftUI

/// The settings panel's Model tab. Every value here traces back to a `Probe` on
/// `ModelSettingsModel` — this view adds no state and makes no judgement of its own about what
/// counts as healthy; `CleanupProbe.verdict` already decided that.
struct ModelSettingsView: View {
    @ObservedObject var model: ModelSettingsModel

    private let labelColumnWidth: CGFloat = 64
    private let healthLabelWidth: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cleanupModelBox
            healthBox
        }
        .padding(.horizontal, 6)
        // Matches the doc comment on `refresh()`: called when the tab opens, and again on Refresh.
        // `.task` fires once per mount, so leaving the tab and coming back re-fires it; toggling
        // some unrelated @Published value on the model does not.
        .task { await model.refresh() }
    }

    // MARK: - CLEANUP MODEL

    private var cleanupModelBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("CLEANUP MODEL")

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Backend")
                    .font(Chicago.ui(11))
                    .foregroundStyle(Chicago.muted)
                    .frame(width: labelColumnWidth, alignment: .leading)
                Text(model.backend.rawValue)
                    .font(Chicago.ui(11))
                    .foregroundStyle(.black)
                Text("from settings.json; change there")
                    .font(Chicago.ui(10))
                    .foregroundStyle(Chicago.muted)
            }

            modelRow
            if model.backend == .ollama {
                modelCaption
            }

            runningRow

            if let mismatch = model.mismatch {
                Text("settings.json says \(mismatch.file) — \(mismatch.running) stays running until Apply.")
                    .font(Chicago.ui(10))
                    .foregroundStyle(Chicago.warning)
            }

            if let applyError = model.applyError {
                Text(applyError)
                    .font(Chicago.ui(10))
                    .foregroundStyle(Chicago.warning)
            }
        }
        .padding(10)
        .chicagoSunken()
    }

    private var modelRow: some View {
        HStack(spacing: 8) {
            Text("Model")
                .font(Chicago.ui(11))
                .foregroundStyle(Chicago.muted)
                .frame(width: labelColumnWidth, alignment: .leading)

            // Backend ≠ ollama: there is no installed-models list to choose from, so the model
            // name is read-only text rather than a dropdown with nothing to populate it.
            if model.backend == .ollama {
                ChicagoDropdown(label: dropdownLabel, width: 260) { dropdownContent }
            } else {
                Text(model.selectedModel)
                    .font(Chicago.ui(11))
                    .foregroundStyle(.black)
            }

            Button(model.isTesting ? "Testing…" : "Test") {
                Task { await model.test(model: model.selectedModel) }
            }
            .buttonStyle(ChicagoButtonStyle())
            .disabled(model.isTesting)

            // Backend ≠ ollama: only Test is live — there is nothing installed to Apply to.
            if model.backend == .ollama {
                Button("Apply") { Task { await model.apply() } }
                    .buttonStyle(ChicagoButtonStyle())

                if selectedModelMissing {
                    Button("Copy") { model.copyPullCommand() }
                        .buttonStyle(ChicagoButtonStyle())
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var modelCaption: some View {
        Group {
            if let entry = installedEntry(for: model.selectedModel) {
                Text("\(entry.parameterSize) · \(entry.quantizationLevel) · \(Self.byteString(entry.size)) · "
                    + "\(entry.family) · think:false sent")
            } else {
                Text("think:false sent")
            }
        }
        .font(Chicago.pixel(8))
        .foregroundStyle(Chicago.muted)
        .padding(.leading, labelColumnWidth + 8)
    }

    private var runningRow: some View {
        let status = probeStatus(for: model.runningModel)
        return HStack(alignment: .top, spacing: 8) {
            Text("Running")
                .font(Chicago.ui(11))
                .foregroundStyle(Chicago.muted)
                .frame(width: labelColumnWidth, alignment: .leading)
            Text(model.runningModel)
                .font(Chicago.ui(11))
                .foregroundStyle(.black)
            StatusWord(text: status.word)
            Text(status.text)
                .font(Chicago.ui(11))
                .foregroundStyle(.black)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedModelMissing: Bool {
        guard case let .result(models, _) = model.installed else { return false }
        return !models.contains { $0.name == model.selectedModel }
    }

    private func installedEntry(for name: String) -> InstalledModel? {
        guard case let .result(models, _) = model.installed else { return nil }
        return models.first { $0.name == name }
    }

    // MARK: - Model dropdown

    private var dropdownLabel: String {
        var parts = [model.selectedModel]
        if let entry = installedEntry(for: model.selectedModel), entry.isReasoningModel {
            parts.append("reasoning")
        }
        parts.append(shortVerdict(for: model.selectedModel))
        return parts.joined(separator: "  ")
    }

    @ViewBuilder
    private var dropdownContent: some View {
        switch model.installed {
        case .notRun, .running, .failed:
            Text("Press Refresh to list installed models")
        case let .result(models, _):
            ForEach(models.sorted { $0.size < $1.size }, id: \.name) { entry in
                Button {
                    model.selectedModel = entry.name
                } label: {
                    dropdownRowLabel(entry)
                }
                .disabled(!entry.canComplete)
            }
        }
    }

    // A model with no completion capability (e.g. nomic-embed-text) is shown disabled with the
    // reason rather than left out of the list — hiding it would leave the user guessing why it's
    // gone the moment they upgrade Ollama and it appears in /api/tags.
    private func dropdownRowLabel(_ entry: InstalledModel) -> Text {
        var text = Text("\(entry.name) · \(Self.byteString(entry.size)) · \(entry.parameterSize) · \(entry.quantizationLevel)")
        if entry.isReasoningModel {
            text = text + Text("  reasoning").foregroundStyle(Chicago.warning)
        }
        text = text + Text("  \(shortVerdict(for: entry.name))")
        if !entry.canComplete {
            text = text + Text("  (embedding — cannot clean)").foregroundStyle(Chicago.warning)
        }
        return text
    }

    private func shortVerdict(for name: String) -> String {
        switch model.verdict(for: name) {
        case .notRun:
            return "—"
        case .running:
            return "testing…"
        case .failed:
            return "FAIL"
        case let .result(result, _):
            switch result.verdict {
            case .pass:
                return "PASS \(Self.elapsedString(result.elapsed))"
            case .fail:
                return "FAIL"
            }
        }
    }

    // MARK: - HEALTH

    private var healthBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("HEALTH")
                Spacer()
                Text(healthCheckedAtText)
                    .font(Chicago.ui(10))
                    .foregroundStyle(Chicago.muted)
            }

            failureCallout

            // Backend ≠ ollama: these three rows have nothing behind them — `refresh()` never
            // queries Ollama for a backend other than `.ollama` — so they are absent, not shown
            // stuck on "— not checked" forever.
            if model.backend == .ollama {
                statusRow("Ollama", ollamaStatus)
                statusRow("Installed", installedStatus)
                statusRow("Loaded", loadedStatus)
            }
            statusRow("Probe", probeStatus(for: model.selectedModel))

            if let box = probeOutputBox {
                VStack(alignment: .leading, spacing: 2) {
                    Text("In:  \(CleanupProbe.fixture)")
                    Text("Out: \(box)")
                }
                .font(Chicago.body(10.5))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white)
                .chicagoSunken()
            }

            plainRow("Last dictation", lastDictationText)

            HStack(alignment: .top) {
                plainRow("Failures", "\(model.failureCount) this session")
                Spacer()
                Button("Open log") { model.openLog() }
                    .buttonStyle(ChicagoButtonStyle())
            }

            HStack {
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                    .buttonStyle(ChicagoButtonStyle())
            }
        }
        .padding(10)
        .chicagoSunken()
    }

    @ViewBuilder
    private var failureCallout: some View {
        switch model.verdict(for: model.selectedModel) {
        case .notRun, .running:
            EmptyView()
        case let .failed(reason, _):
            calloutText("\(model.selectedModel) — probe failed: \(reason)")
        case let .result(result, _):
            switch result.verdict {
            case .pass:
                EmptyView()
            case let .fail(reason):
                calloutText(calloutMessage(for: model.selectedModel, reason: reason, remedy: result.remedy))
            }
        }
    }

    private func calloutText(_ text: String) -> some View {
        Text(text)
            .font(Chicago.ui(11))
            .foregroundStyle(Chicago.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    // The remedy and the reason are the same sentence for some errors (a leak names its own fix)
    // and different sentences for others (a 404's reason is the raw HTTP body; its remedy is
    // "install it or pick another") — shown once each, never the same sentence twice.
    private func calloutMessage(for name: String, reason: String, remedy: String?) -> String {
        guard let remedy, remedy != reason else { return "\(name) — FAILS probe: \(reason)" }
        return "\(name) — FAILS probe: \(reason) → \(remedy)"
    }

    private var ollamaStatus: (word: String, text: String) {
        switch model.version {
        case .notRun:
            return ("—", "not checked")
        case .running:
            return ("—", "checking…")
        case let .failed(reason, checkedAt):
            return ("FAIL", "\(reason) (\(Self.time(checkedAt)))")
        case let .result(version, checkedAt):
            return ("OK", "v\(version) at localhost:11434 (\(Self.time(checkedAt)))")
        }
    }

    private var installedStatus: (word: String, text: String) {
        switch model.installed {
        case .notRun:
            return ("—", "not checked")
        case .running:
            return ("—", "checking…")
        case let .failed(reason, checkedAt):
            return ("FAIL", "\(reason) (\(Self.time(checkedAt)))")
        case let .result(models, checkedAt):
            guard let entry = models.first(where: { $0.name == model.selectedModel }) else {
                return ("FAIL", "\(model.selectedModel) is not installed (\(Self.time(checkedAt)))")
            }
            let reasoning = entry.isReasoningModel ? " · reasoning-capable" : ""
            return (
                "OK",
                "\(Self.byteString(entry.size)) · \(entry.parameterSize) · \(entry.quantizationLevel)"
                    + "\(reasoning) (\(Self.time(checkedAt)))"
            )
        }
    }

    private var loadedStatus: (word: String, text: String) {
        switch model.loaded {
        case .notRun:
            return ("—", "not checked")
        case .running:
            return ("—", "checking…")
        case let .failed(reason, checkedAt):
            return ("FAIL", "\(reason) (\(Self.time(checkedAt)))")
        case let .result(models, checkedAt):
            if models.contains(where: { $0.name == model.selectedModel }) {
                return ("—", "warm (\(Self.time(checkedAt)))")
            }
            if let entry = installedEntry(for: model.selectedModel) {
                return ("—", "cold; next call loads \(Self.byteString(entry.size)) first (\(Self.time(checkedAt)))")
            }
            return ("—", "cold (\(Self.time(checkedAt)))")
        }
    }

    // Shared by the HEALTH "Probe" row (always the selected model) and the CLEANUP MODEL "Running"
    // row (always the running model) — a verdict is a property of the model it was measured on,
    // not of which row is asking, so both rows read it through the same lookup.
    private func probeStatus(for name: String) -> (word: String, text: String) {
        switch model.verdict(for: name) {
        case .notRun:
            return ("—", "not checked")
        case .running:
            return ("—", "testing…")
        case let .failed(reason, checkedAt):
            return ("FAIL", "\(reason) (\(Self.time(checkedAt)))")
        case let .result(result, checkedAt):
            let warmth = result.warm ? "warm" : "cold"
            switch result.verdict {
            case let .pass(warnings):
                let extra = warnings.isEmpty ? "" : " · " + warnings.joined(separator: "; ")
                return ("PASS", "\(Self.elapsedString(result.elapsed)) \(warmth)\(extra) (\(Self.time(checkedAt)))")
            case let .fail(reason):
                return ("FAIL", "\(Self.elapsedString(result.elapsed)) \(warmth) · \(reason) (\(Self.time(checkedAt)))")
            }
        }
    }

    // `ProbeResult` carries the verdict and the elapsed time, never the model's raw completion —
    // `CleanupError.reasoningLeaked` only names a character count, not the 20,945 characters
    // themselves. So this box can show what was sent (the fixture, always known) and the verdict's
    // own reason text (which does carry the measured count), but not a literal transcript of the
    // leak. See the report for why the mock's raw `<think>…` preview isn't reproduced here.
    private var probeOutputBox: String? {
        switch model.verdict(for: model.selectedModel) {
        case .notRun, .running:
            return nil
        case let .failed(reason, _):
            return Self.truncated(reason)
        case let .result(result, _):
            // Shown for a pass as much as a failure: the point of Test is to read what the model did
            // to the sentence, and a verdict of PASS with no visible output is just a number.
            if let output = result.output { return Self.truncated(output) }
            guard case let .fail(reason) = result.verdict else { return nil }
            return Self.truncated(reason)
        }
    }

    private var healthCheckedAtText: String {
        let dates = [
            Self.checkedAt(model.version),
            Self.checkedAt(model.installed),
            Self.checkedAt(model.loaded),
            Self.checkedAt(model.verdict(for: model.selectedModel)),
        ].compactMap { $0 }
        guard let newest = dates.max() else { return "Checked — not checked" }
        return "Checked \(Self.time(newest))"
    }

    private var lastDictationText: String {
        guard let failure = model.lastFailure else { return "none this session" }
        let latency = model.lastDictationLatency.map { Self.elapsedString($0) } ?? "latency n/a"
        return "\(Self.time(failure.date))  \(failure.stage) \(latency) → nothing pasted: \(failure.reason)"
    }

    // MARK: - Row helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Chicago.pixel(8))
            .tracking(0.7)
            .foregroundStyle(Chicago.muted)
    }

    private func statusRow(_ label: String, _ status: (word: String, text: String)) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(Chicago.ui(11))
                .foregroundStyle(Chicago.muted)
                .frame(width: healthLabelWidth, alignment: .leading)
            StatusWord(text: status.word)
                .frame(width: 36, alignment: .leading)
            Text(status.text)
                .font(Chicago.ui(11))
                .foregroundStyle(.black)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func plainRow(_ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(Chicago.ui(11))
                .foregroundStyle(Chicago.muted)
                .frame(width: healthLabelWidth, alignment: .leading)
            Text(text)
                .font(Chicago.ui(11))
                .foregroundStyle(.black)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Formatting

    private static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
    }

    private static func elapsedString(_ seconds: TimeInterval) -> String {
        "\(seconds.formatted(.number.precision(.significantDigits(3)))) s"
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // The display is bounded; the data underneath it is not — `reason` can carry a measured
    // 20,945-character leak verbatim, and pasting it whole into a fixed-width sunken box would
    // make the box as unbounded as the leak it is reporting on.
    private static func truncated(_ text: String, limit: Int = 600) -> String {
        guard text.count > limit else { return text }
        let count = text.count.formatted(.number.locale(Locale(identifier: "en_US")))
        return "\(text.prefix(limit))… (\(count) characters)"
    }

    // `.notRun` must never render as OK, blank, or any other guess — every row that has not been
    // probed yet says so, in the same three words, everywhere in this view.
    private static func checkedAt<Value>(_ probe: Probe<Value>) -> Date? {
        switch probe {
        case .notRun, .running:
            return nil
        case let .failed(_, checkedAt):
            return checkedAt
        case let .result(_, checkedAt):
            return checkedAt
        }
    }
}

/// A private Chicago primitive: the three words a status column may ever show. `FAIL` is the only
/// one that carries colour — status is never colour-only, the word already says it, and `OK`/`PASS`
/// stay black on purpose.
private struct StatusWord: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Chicago.pixel(9))
            .foregroundStyle(text == "FAIL" ? Chicago.warning : .black)
    }
}
