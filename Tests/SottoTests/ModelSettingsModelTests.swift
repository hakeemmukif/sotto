import Foundation
import Testing
@testable import Sotto

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

// Real output recorded from qwen2.5:3b-instruct on CleanupProbe.fixture, 2026-09-15.
private let goodOutput =
    "I was thinking we should run pnpm install first and then what's the capital of France anyway?"

// Two entries trimmed from the real /api/tags capture (Ollama 0.34.0, 2026-09-15): the instruct
// model that passes and the thinking model that leaks, which is the pair the panel exists to tell
// apart.
private let tagsFixture = Data("""
{"models":[{"name":"qwen2.5:3b-instruct","size":1929912432,"details":{"family":"qwen2","parameter_size":"3.1B","quantization_level":"Q4_K_M"},"capabilities":["completion","tools"]},{"name":"qwen3:4b","size":2497293931,"details":{"family":"qwen3","parameter_size":"4.0B","quantization_level":"Q4_K_M"},"capabilities":["completion","tools","thinking"]}]}
""".utf8)

private func installedFixture() throws -> [InstalledModel] {
    try JSONDecoder().decode(OllamaProbe.TagsResponse.self, from: tagsFixture).models
}

private struct StubCleaner: Cleaner {
    let result: String

    func clean(_ transcript: String, system: String) async throws -> String {
        result
    }
}

private struct FailingCleaner: Cleaner {
    let error: CleanupError

    func clean(_ transcript: String, system: String) async throws -> String {
        throw error
    }
}

private struct OddError: Error, CustomStringConvertible {
    var description: String { "something no one modelled" }
}

private struct OddlyFailingCleaner: Cleaner {
    func clean(_ transcript: String, system: String) async throws -> String {
        throw OddError()
    }
}

/// Hands out a scripted sequence so an elapsed time is exact rather than wall-clock flaky. The last
/// date is held once the script runs out, so a test only scripts the readings it asserts on.
private final class StubClock {
    private var times: [Date]

    init(_ times: [Date]) {
        self.times = times
    }

    func next() -> Date {
        guard let first = times.first else { preconditionFailure("clock exhausted") }
        if times.count > 1 { times.removeFirst() }
        return first
    }
}

private final class Spy {
    var running: String
    var file: String
    var writes: [String] = []
    var applied: [String] = []
    var copied: [String] = []
    var opened: [URL] = []

    init(running: String) {
        self.running = running
        file = running
    }
}

@MainActor
private func makeModel(
    spy: Spy,
    backend: CleanupBackend = .ollama,
    register: CleanupFailureRegister = CleanupFailureRegister(),
    clock: StubClock = StubClock([epoch]),
    fetchVersion: @escaping () async throws -> String = { "0.34.0" },
    fetchInstalled: @escaping () async throws -> [InstalledModel] = { try installedFixture() },
    fetchLoaded: @escaping () async throws -> [LoadedModel] = { [] },
    readFileModel: @escaping () throws -> String = { "qwen2.5:3b-instruct" },
    writeFails: Bool = false,
    makeCleaner: @escaping (String) -> any Cleaner = { _ in StubCleaner(result: goodOutput) }
) -> ModelSettingsModel {
    ModelSettingsModel(
        backend: backend,
        register: register,
        now: { clock.next() },
        fetchVersion: fetchVersion,
        fetchInstalledModels: fetchInstalled,
        fetchLoadedModels: fetchLoaded,
        readFileModel: readFileModel,
        writeFileModel: { name in
            spy.writes.append(name)
            if writeFails { throw SettingsFile.FileError.notAJSONObject }
            spy.file = name
        },
        makeCleaner: makeCleaner,
        applyToSlot: { _, name in
            spy.applied.append(name)
            spy.running = name
        },
        slotModel: { spy.running },
        copyToPasteboard: { spy.copied.append($0) },
        openFile: { spy.opened.append($0) }
    )
}

@Suite("ModelSettingsModel — the settings panel's readings, offline")
@MainActor
struct ModelSettingsModelTests {
    @Test func everyRowStartsNotRunRatherThanOptimistic() {
        let model = makeModel(spy: Spy(running: "qwen2.5:3b-instruct"))

        #expect(model.version == .notRun)
        #expect(model.installed == .notRun)
        #expect(model.loaded == .notRun)
        #expect(model.fileModel == .notRun)
        #expect(model.verdict(for: "qwen2.5:3b-instruct") == .notRun)
        #expect(model.runningModel == "qwen2.5:3b-instruct")
        #expect(model.selectedModel == "qwen2.5:3b-instruct")
    }

    @Test func aRefreshFillsTheThreeOllamaRowsAndTheFileRow() async {
        let model = makeModel(
            spy: Spy(running: "qwen2.5:3b-instruct"),
            fetchLoaded: { [LoadedModel(name: "qwen2.5:3b-instruct", expiresAt: "", sizeVRAM: 1)] }
        )

        await model.refresh()

        #expect(model.version == .result("0.34.0", checkedAt: epoch))
        guard case let .result(installed, _) = model.installed else {
            Issue.record("expected .result, got \(model.installed)")
            return
        }
        #expect(installed.map(\.name) == ["qwen2.5:3b-instruct", "qwen3:4b"])
        guard case let .result(loaded, _) = model.loaded else {
            Issue.record("expected .result, got \(model.loaded)")
            return
        }
        #expect(loaded.map(\.name) == ["qwen2.5:3b-instruct"])
        #expect(model.fileModel == .result("qwen2.5:3b-instruct", checkedAt: epoch))
    }

    @Test func aFailingFetchFailsOnlyItsOwnRow() async {
        let model = makeModel(
            spy: Spy(running: "qwen2.5:3b-instruct"),
            fetchVersion: { throw CleanupError.backendUnavailable }
        )

        await model.refresh()

        #expect(model.version == .failed(reason: CleanupError.backendUnavailable.description, checkedAt: epoch))
        guard case let .result(installed, _) = model.installed else {
            Issue.record("expected .result, got \(model.installed)")
            return
        }
        #expect(installed.count == 2)
        guard case .result = model.loaded else {
            Issue.record("expected .result, got \(model.loaded)")
            return
        }
    }

    @Test func anUnreadableSettingsFileFailsTheFileRowRatherThanReportingAModel() async {
        let model = makeModel(
            spy: Spy(running: "qwen2.5:3b-instruct"),
            readFileModel: { throw SettingsError.missingKey("cleanupModel") }
        )

        await model.refresh()

        guard case let .failed(reason, _) = model.fileModel else {
            Issue.record("expected .failed, got \(model.fileModel)")
            return
        }
        #expect(reason.contains("cleanupModel"))
    }

    // The exact state the user was in: settings.json was edited at 22:42, the process that launched
    // at 21:58 was still running the old model, and nothing said so.
    @Test func theMismatchSurfacesBothModelsWhenTheFileAndTheSlotDisagree() async {
        let model = makeModel(spy: Spy(running: "qwen3:8b"), readFileModel: { "qwen2.5:3b-instruct" })

        await model.refresh()

        #expect(model.mismatch?.file == "qwen2.5:3b-instruct")
        #expect(model.mismatch?.running == "qwen3:8b")
    }

    @Test func theMismatchIsClearWhenTheFileAndTheSlotAgree() async {
        let model = makeModel(spy: Spy(running: "qwen2.5:3b-instruct"), readFileModel: { "qwen2.5:3b-instruct" })

        await model.refresh()

        #expect(model.mismatch == nil)
    }

    @Test func aVerdictIsVisibleOnlyForTheModelItWasMeasuredOn() async {
        let model = makeModel(spy: Spy(running: "qwen2.5:3b-instruct"))

        await model.test(model: "qwen2.5:3b-instruct")

        guard case let .result(result, _) = model.verdict(for: "qwen2.5:3b-instruct") else {
            Issue.record("expected .result, got \(model.verdict(for: "qwen2.5:3b-instruct"))")
            return
        }
        #expect(result.verdict == .pass(warnings: []))
        #expect(model.verdict(for: "qwen3:4b") == .notRun)
    }

    @Test func testingASelectedModelNeitherWritesTheFileNorSwapsTheSlot() async {
        let spy = Spy(running: "qwen2.5:3b-instruct")
        let model = makeModel(spy: spy)
        model.selectedModel = "qwen3:4b"

        await model.test(model: "qwen3:4b")

        #expect(spy.writes.isEmpty)
        #expect(spy.applied.isEmpty)
        #expect(spy.running == "qwen2.5:3b-instruct")
        #expect(model.runningModel == "qwen2.5:3b-instruct")
    }

    @Test func warmIsReadFromPsBeforeTheRoundTripSoTheBudgetIsTheWarmOne() async {
        let model = makeModel(
            spy: Spy(running: "qwen2.5:3b-instruct"),
            clock: StubClock([epoch, epoch.addingTimeInterval(6)]),
            fetchLoaded: { [LoadedModel(name: "qwen2.5:3b-instruct", expiresAt: "", sizeVRAM: 1)] }
        )

        await model.test(model: "qwen2.5:3b-instruct")

        guard case let .result(result, _) = model.verdict(for: "qwen2.5:3b-instruct") else {
            Issue.record("expected .result, got \(model.verdict(for: "qwen2.5:3b-instruct"))")
            return
        }
        #expect(result.warm)
        #expect(result.elapsed == 6)
        guard case let .pass(warnings) = result.verdict else {
            Issue.record("expected .pass, got \(result.verdict)")
            return
        }
        #expect(warnings.contains { $0.contains("warm") })
    }

    // No fallback: without /api/ps there is no warm/cold, and a 6 s reading judged against the
    // wrong budget is worse than no reading at all.
    @Test func anUnreachablePsFailsTheVerdictRatherThanGuessingCold() async {
        let model = makeModel(
            spy: Spy(running: "qwen2.5:3b-instruct"),
            fetchLoaded: { throw CleanupError.backendUnavailable }
        )

        await model.test(model: "qwen2.5:3b-instruct")

        guard case let .failed(reason, _) = model.verdict(for: "qwen2.5:3b-instruct") else {
            Issue.record("expected .failed, got \(model.verdict(for: "qwen2.5:3b-instruct"))")
            return
        }
        #expect(reason.contains(CleanupError.backendUnavailable.description))
    }

    // The first of the two unhealthy states: absent. 404 in milliseconds.
    @Test func aModelThatIsNotInstalledFailsWithTheInstallRemedy() async {
        let model = makeModel(
            spy: Spy(running: "qwen2.5:3b-instruct"),
            makeCleaner: { _ in
                FailingCleaner(error: .requestFailed(status: 404, body: "model 'qwen3:8b' not found"))
            }
        )

        await model.test(model: "qwen3:8b")

        guard case let .result(result, _) = model.verdict(for: "qwen3:8b") else {
            Issue.record("expected .result, got \(model.verdict(for: "qwen3:8b"))")
            return
        }
        guard case .fail = result.verdict else {
            Issue.record("expected .fail, got \(result.verdict)")
            return
        }
        #expect(result.remedy?.contains("install") == true)
    }

    // The second: present but wrong. qwen3:4b answered with 20,945 characters of reasoning in
    // 63.9 s on Ollama 0.34.0, measured 2026-09-15 — installed, reachable, and unusable.
    @Test func aReasoningLeakFailsWithItsOwnElapsedTime() async {
        let model = makeModel(
            spy: Spy(running: "qwen2.5:3b-instruct"),
            clock: StubClock([epoch, epoch.addingTimeInterval(64)]),
            makeCleaner: { _ in FailingCleaner(error: .reasoningLeaked(model: "qwen3:4b", characters: 20_945)) }
        )

        await model.test(model: "qwen3:4b")

        guard case let .result(result, _) = model.verdict(for: "qwen3:4b") else {
            Issue.record("expected .result, got \(model.verdict(for: "qwen3:4b"))")
            return
        }
        guard case let .fail(reason) = result.verdict else {
            Issue.record("expected .fail, got \(result.verdict)")
            return
        }
        #expect(reason.contains("20,945"))
        #expect(result.elapsed == 64)
        #expect(result.remedy?.contains("different model") == true)
    }

    @Test func anErrorNoOneModelledFailsTheRowWithItsOwnText() async {
        let model = makeModel(spy: Spy(running: "qwen2.5:3b-instruct"), makeCleaner: { _ in OddlyFailingCleaner() })

        await model.test(model: "qwen3:4b")

        guard case let .failed(reason, _) = model.verdict(for: "qwen3:4b") else {
            Issue.record("expected .failed, got \(model.verdict(for: "qwen3:4b"))")
            return
        }
        #expect(reason.contains("something no one modelled"))
    }

    @Test func aFailingWriteNeverSwapsTheSlot() async {
        let spy = Spy(running: "qwen2.5:3b-instruct")
        let model = makeModel(spy: spy, writeFails: true)
        model.selectedModel = "qwen3:4b"

        await model.apply()

        #expect(spy.writes == ["qwen3:4b"])
        #expect(spy.applied.isEmpty)
        #expect(spy.running == "qwen2.5:3b-instruct")
        #expect(model.runningModel == "qwen2.5:3b-instruct")
        #expect(model.applyError != nil)
    }

    @Test func applyWritesTheFileBeforeSwappingTheSlot() async {
        let spy = Spy(running: "qwen2.5:3b-instruct")
        let model = makeModel(spy: spy, readFileModel: { spy.file })
        model.selectedModel = "qwen3:4b"

        await model.apply()

        #expect(spy.writes == ["qwen3:4b"])
        #expect(spy.applied == ["qwen3:4b"])
        #expect(model.runningModel == "qwen3:4b")
        #expect(model.fileModel == .result("qwen3:4b", checkedAt: epoch))
        #expect(model.mismatch == nil)
        #expect(model.applyError == nil)
    }

    @Test func applyingClearsThePreviousModelsVerdict() async {
        let spy = Spy(running: "qwen2.5:3b-instruct")
        let model = makeModel(spy: spy)
        await model.test(model: "qwen2.5:3b-instruct")
        #expect(model.verdict(for: "qwen2.5:3b-instruct") != .notRun)

        model.selectedModel = "qwen3:4b"
        await model.apply()

        #expect(model.verdict(for: "qwen2.5:3b-instruct") == .notRun)
    }

    @Test func applyingKeepsTheVerdictOfTheModelBeingApplied() async {
        let spy = Spy(running: "qwen2.5:3b-instruct")
        let model = makeModel(spy: spy)
        await model.test(model: "qwen3:4b")

        model.selectedModel = "qwen3:4b"
        await model.apply()

        #expect(model.verdict(for: "qwen3:4b") != .notRun)
    }

    @Test func aNonOllamaBackendNeverQueriesOllama() async {
        let spy = Spy(running: "gpt-4o-mini")
        let model = makeModel(
            spy: spy,
            backend: .openai,
            fetchVersion: {
                Issue.record("/api/version must not be queried for a non-ollama backend")
                return ""
            },
            fetchInstalled: {
                Issue.record("/api/tags must not be queried for a non-ollama backend")
                return []
            },
            fetchLoaded: {
                Issue.record("/api/ps must not be queried for a non-ollama backend")
                return []
            },
            readFileModel: { "gpt-4o-mini" }
        )

        await model.refresh()
        await model.test(model: "gpt-4o-mini")

        #expect(model.version == .notRun)
        #expect(model.installed == .notRun)
        #expect(model.loaded == .notRun)
        #expect(model.fileModel == .result("gpt-4o-mini", checkedAt: epoch))
        guard case .result = model.verdict(for: "gpt-4o-mini") else {
            Issue.record("expected .result, got \(model.verdict(for: "gpt-4o-mini"))")
            return
        }
    }

    @Test func theRegisterSuppliesTheLastDictationLatencyAndFailure() {
        let register = CleanupFailureRegister()
        register.record(sequence: 1, state: .cleaning, at: epoch)
        register.record(
            sequence: 1,
            state: .failed(stage: .cleanup, reason: "cleanup request failed (HTTP 404)"),
            at: epoch.addingTimeInterval(64)
        )
        let model = makeModel(spy: Spy(running: "qwen2.5:3b-instruct"), register: register)

        #expect(model.lastDictationLatency == 64)
        #expect(model.lastFailure?.stage == .cleanup)
        #expect(model.lastFailure?.reason == "cleanup request failed (HTTP 404)")
        #expect(model.failureCount == 1)
    }

    @Test func copyPullCommandPutsTheSelectedModelsPullCommandOnThePasteboard() {
        let spy = Spy(running: "qwen2.5:3b-instruct")
        let model = makeModel(spy: spy)
        model.selectedModel = "qwen3:8b"

        model.copyPullCommand()

        #expect(spy.copied == ["ollama pull qwen3:8b"])
    }

    @Test func openLogOpensTheSottoLog() {
        let spy = Spy(running: "qwen2.5:3b-instruct")
        let model = makeModel(spy: spy)

        model.openLog()

        #expect(spy.opened.count == 1)
        #expect(spy.opened.first?.path.hasSuffix("Library/Logs/Sotto.log") == true)
    }
}
