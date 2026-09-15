import Combine
import Foundation

/// One reading of something outside this process. There is deliberately no `Bool` anywhere in it:
/// a check modelled as true/false has no way to say "not checked yet", so it renders a green tick
/// for a reading that was never taken. `.notRun` is "— not checked", and it is never OK.
enum Probe<Value> {
    case notRun
    case running
    case result(Value, checkedAt: Date)
    case failed(reason: String, checkedAt: Date)
}

extension Probe: Equatable where Value: Equatable {}

/// One real round-trip of `CleanupProbe.fixture` through a named model. `remedy` is set only when
/// the model threw a `CleanupError`, because that is the only thing `CleanupProbe.remedy` can tell
/// apart — an absent model ("install it or pick another") from a present but unusable one.
struct ProbeResult: Equatable {
    let verdict: ProbeVerdict
    let elapsed: TimeInterval
    let warm: Bool
    let remedy: String?
}

/// Backs the settings panel's model tab: what Ollama reports, what settings.json names, what this
/// process is actually running, and the verdict from a real round-trip — which is the only thing
/// here that counts as health. Being installed is a precondition, not health: qwen3:4b was
/// installed and reachable and still returned 20,945 characters of reasoning in 63.9 s for a
/// nine-word transcript (Ollama 0.34.0, measured 2026-09-15), so a tick on "installed" would have
/// passed it.
///
/// Every collaborator is a closure for the same reason as `MenuBarController`: the real ones are a
/// live HTTP daemon, the settings file on disk, the running cleaner slot and the pasteboard, none
/// of which a test may touch.
@MainActor
final class ModelSettingsModel: ObservableObject {
    let backend: CleanupBackend

    private let register: CleanupFailureRegister
    private let now: () -> Date
    private let fetchVersion: () async throws -> String
    private let fetchInstalledModels: () async throws -> [InstalledModel]
    private let fetchLoadedModels: () async throws -> [LoadedModel]
    private let readFileModel: () throws -> String
    private let writeFileModel: (String) throws -> Void
    private let makeCleaner: (String) -> any Cleaner
    private let applyToSlot: (any Cleaner, String) -> Void
    private let slotModel: () -> String
    private let copyToPasteboard: (String) -> Void
    private let openFile: (URL) -> Void
    private var registerObserver: AnyCancellable?

    @Published private(set) var version: Probe<String> = .notRun
    @Published private(set) var installed: Probe<[InstalledModel]> = .notRun
    @Published private(set) var loaded: Probe<[LoadedModel]> = .notRun
    @Published private(set) var fileModel: Probe<String> = .notRun
    @Published private(set) var runningModel: String
    @Published var selectedModel: String
    @Published private(set) var isTesting = false
    @Published private(set) var applyError: String?
    // Keyed by model name: a PASS measured on qwen2.5:3b-instruct must never be rendered beside
    // qwen3:4b, because a verdict is a property of the model it was measured on, not of the panel.
    @Published private var verdicts: [String: Probe<ProbeResult>] = [:]

    init(
        backend: CleanupBackend,
        register: CleanupFailureRegister,
        now: @escaping () -> Date,
        fetchVersion: @escaping () async throws -> String,
        fetchInstalledModels: @escaping () async throws -> [InstalledModel],
        fetchLoadedModels: @escaping () async throws -> [LoadedModel],
        readFileModel: @escaping () throws -> String,
        writeFileModel: @escaping (String) throws -> Void,
        makeCleaner: @escaping (String) -> any Cleaner,
        applyToSlot: @escaping (any Cleaner, String) -> Void,
        slotModel: @escaping () -> String,
        copyToPasteboard: @escaping (String) -> Void,
        openFile: @escaping (URL) -> Void
    ) {
        self.backend = backend
        self.register = register
        self.now = now
        self.fetchVersion = fetchVersion
        self.fetchInstalledModels = fetchInstalledModels
        self.fetchLoadedModels = fetchLoadedModels
        self.readFileModel = readFileModel
        self.writeFileModel = writeFileModel
        self.makeCleaner = makeCleaner
        self.applyToSlot = applyToSlot
        self.slotModel = slotModel
        self.copyToPasteboard = copyToPasteboard
        self.openFile = openFile

        let current = slotModel()
        runningModel = current
        selectedModel = current

        // The register is written from the dictation queue while this panel is open, so without
        // this the panel shows whatever the failure state was at the moment it was opened.
        registerObserver = NotificationCenter.default
            .publisher(for: CleanupFailureRegister.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Derived, never stored: a stored mismatch flag outlives the reading it came from, which is
    /// the failure this whole panel exists to prevent. Both models are returned because picking one
    /// is what hid the problem — the file said one thing at 22:42 and the process launched at 21:58
    /// was still running the other.
    var mismatch: (file: String, running: String)? {
        guard case let .result(file, _) = fileModel, file != runningModel else { return nil }
        return (file, runningModel)
    }

    var lastDictationLatency: TimeInterval? { register.lastDictation?.cleanupLatency }

    var lastFailure: (date: Date, stage: FailureStage, reason: String)? { register.lastFailure }

    var failureCount: Int { register.failureCount }

    /// An absent key is not a missing value to fill in: it means this model has not been probed.
    func verdict(for model: String) -> Probe<ProbeResult> {
        verdicts[model] ?? .notRun
    }

    /// The three cheap GETs plus the file read. Called when the tab opens and when the user presses
    /// Refresh — never on a timer, because a panel that polls a local daemon keeps a 4 GB model
    /// resident for nothing.
    func refresh() async {
        runningModel = slotModel()
        do {
            let model = try readFileModel()
            fileModel = .result(model, checkedAt: now())
        } catch {
            fileModel = .failed(reason: Self.reason(for: error), checkedAt: now())
        }

        guard backend == .ollama else { return }

        version = .running
        installed = .running
        loaded = .running
        version = await read(fetchVersion)
        installed = await read(fetchInstalledModels)
        loaded = await read(fetchLoadedModels)
    }

    /// Runs the fixture through `model` and judges the result. It runs against the selected model
    /// rather than the running one, so a broken model is never applied just to discover it is
    /// broken — it neither writes the file nor swaps the slot.
    func test(model: String) async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }
        verdicts[model] = .running

        let warm: Bool
        if backend == .ollama {
            do {
                warm = try await fetchLoadedModels().contains { $0.name == model }
            } catch {
                // No fallback to cold: CleanupProbe's budget is 5 s warm against 15 s cold, so a
                // reading judged against a guessed budget is worse than no reading at all.
                verdicts[model] = .failed(
                    reason: "warm or cold could not be established: \(Self.reason(for: error))",
                    checkedAt: now()
                )
                return
            }
        } else {
            // A remote backend holds no model in local memory, so every call pays the full network
            // cost and is judged against the cold budget.
            warm = false
        }

        // The clock is read twice, both times around the round-trip, so `elapsed` is the model's
        // time and not /api/ps's.
        let started = now()
        do {
            let output = try await makeCleaner(model).clean(CleanupProbe.fixture, system: Prompts.cleanup)
            let finished = now()
            let elapsed = finished.timeIntervalSince(started)
            verdicts[model] = .result(
                ProbeResult(
                    verdict: CleanupProbe.verdict(output: output, error: nil, elapsed: elapsed, warm: warm),
                    elapsed: elapsed,
                    warm: warm,
                    remedy: nil
                ),
                checkedAt: finished
            )
        } catch let error as CleanupError {
            let finished = now()
            let elapsed = finished.timeIntervalSince(started)
            verdicts[model] = .result(
                ProbeResult(
                    verdict: CleanupProbe.verdict(output: nil, error: error, elapsed: elapsed, warm: warm),
                    elapsed: elapsed,
                    warm: warm,
                    remedy: CleanupProbe.remedy(for: error, elapsed: elapsed)
                ),
                checkedAt: finished
            )
        } catch {
            verdicts[model] = .failed(reason: Self.reason(for: error), checkedAt: now())
        }
    }

    func apply() async {
        let target = selectedModel
        let previous = runningModel
        applyError = nil
        do {
            // Write first, always: `SettingsFile.write` validates the new bytes by decoding them,
            // and if it throws nothing has swapped — so this process never runs a configuration the
            // file on disk does not have.
            try writeFileModel(target)
        } catch {
            applyError = Self.reason(for: error)
            return
        }
        applyToSlot(makeCleaner(target), target)
        // The replaced model's verdict described a model that is no longer running. The applied
        // model keeps its own, which is usually the PASS that justified applying it.
        if previous != target {
            verdicts[previous] = nil
        }
        await refresh()
    }

    func copyPullCommand() {
        copyToPasteboard("ollama pull \(selectedModel)")
    }

    func openLog() {
        openFile(AppDelegate.diagnosticsPath)
    }

    private func read<Value>(_ fetch: () async throws -> Value) async -> Probe<Value> {
        do {
            let value = try await fetch()
            return .result(value, checkedAt: now())
        } catch {
            return .failed(reason: Self.reason(for: error), checkedAt: now())
        }
    }

    // `String(describing:)` uses an error's own `description` when it has one, and every
    // `CleanupError` does — the sentence written for the user to read, never a paraphrase of it.
    private static func reason(for error: Error) -> String {
        String(describing: error)
    }
}
