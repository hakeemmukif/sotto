import AppKit
import Carbon
import CoreGraphics
import Foundation
import Testing
@testable import Sotto

// The only source of an `InsertionPermit` is a real `TextInserter` — its initialiser is fileprivate
// to TextInserter.swift — so even the stubs go through the real secure-input check.
private func permitting(secureInput: Bool) -> @Sendable () throws -> InsertionPermit {
    let inserter = TextInserter(
        pasteboard: NSPasteboard(name: NSPasteboard.Name("com.hakeem.sotto.dictation-tests-\(UUID().uuidString)")),
        mode: .paste,
        isSecureInputEnabled: { secureInput }
    )
    return { try inserter.permitInsertion() }
}

private struct StubCleaner: Cleaner {
    let body: @Sendable (String, String) async throws -> String

    func clean(_ transcript: String, system: String) async throws -> String {
        try await body(transcript, system)
    }
}

private struct MissingStubTranscript: Error {
    let recording: String
}

private struct Change: Equatable {
    let job: Int
    let state: DictationState
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [Change] = []
    private var insertions: [String] = []
    private var cleanups: [String] = []
    private var transcriptions: [String] = []

    func record(job: Int, state: DictationState) {
        lock.lock()
        changes.append(Change(job: job, state: state))
        lock.unlock()
    }

    func recordInsertion(_ text: String) {
        lock.lock()
        insertions.append(text)
        lock.unlock()
    }

    func recordCleanup(_ transcript: String) {
        lock.lock()
        cleanups.append(transcript)
        lock.unlock()
    }

    func recordTranscription(_ transcript: String) {
        lock.lock()
        transcriptions.append(transcript)
        lock.unlock()
    }

    var allChanges: [Change] {
        lock.lock()
        defer { lock.unlock() }
        return changes
    }

    var insertedTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return insertions
    }

    var cleanupOrder: [String] {
        lock.lock()
        defer { lock.unlock() }
        return cleanups
    }

    var startedTranscriptions: [String] {
        lock.lock()
        defer { lock.unlock() }
        return transcriptions
    }

    func states(forJob job: Int) -> [DictationState] {
        allChanges.filter { $0.job == job }.map(\.state)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func recordingURL(_ index: Int) -> URL {
    URL(fileURLWithPath: "/tmp/sotto-dictation-test-job\(index).wav")
}

private func recordingIndex(of url: URL) -> Int? {
    Int(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "sotto-dictation-test-job", with: ""))
}

private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func makeController(
    log: Log,
    starts: Counter,
    stops: Counter,
    transcripts: [Int: String],
    transcribeDelays: [Int: TimeInterval] = [:],
    tooShort: Set<Int> = [],
    cleaner: Cleaner?,
    secureInput: Bool = false,
    microphoneAuthorized: Bool = true
) -> DictationController {
    DictationController(
        hotkey: .fn,
        startRecording: { _ = starts.next() },
        stopRecording: {
            let index = stops.next()
            return tooShort.contains(index) ? nil : recordingURL(index)
        },
        transcribe: { url in
            guard let index = recordingIndex(of: url), let transcript = transcripts[index] else {
                throw MissingStubTranscript(recording: url.lastPathComponent)
            }
            log.recordTranscription(transcript)
            if let delay = transcribeDelays[index] { Thread.sleep(forTimeInterval: delay) }
            return transcript
        },
        cleaner: cleaner,
        permitInsertion: permitting(secureInput: secureInput),
        insert: { text, _ in log.recordInsertion(text) },
        isMicrophoneAuthorized: { microphoneAuthorized },
        onStateChange: { log.record(job: $0, state: $1) }
    )
}

private func cleanerAppending(_ suffix: String, log: Log) -> StubCleaner {
    StubCleaner { transcript, _ in
        log.recordCleanup(transcript)
        return transcript + suffix
    }
}

@Suite("Hotkey grammar — the settings string to the typed value", .serialized)
struct HotkeyGrammarTests {
    @Test func theExampleSettingsHotkeyParses() throws {
        #expect(try Hotkey(settingsValue: "fn") == .fn)
        #expect(try Hotkey(settingsValue: "FN") == .fn)
    }

    @Test func aChordParsesToItsKeycodeAndModifiers() throws {
        #expect(try Hotkey(settingsValue: "ctrl+space") == .chord(keyCode: Int64(kVK_Space), modifiers: .maskControl))
        #expect(
            try Hotkey(settingsValue: "cmd+shift+f13")
                == .chord(keyCode: Int64(kVK_F13), modifiers: [.maskCommand, .maskShift])
        )
        #expect(try Hotkey(settingsValue: "opt+escape") == .chord(keyCode: Int64(kVK_Escape), modifiers: .maskAlternate))
    }

    // The house rule this seam exists for: an unreadable hotkey must not quietly become `fn`.
    @Test func anUnparseableHotkeyThrowsRatherThanDefaultingToFn() {
        for value in ["", "banana", "cmd+banana", "ctrl+", "fn+space", "hyper+space"] {
            #expect(throws: DictationError.unparseableHotkey(value)) {
                try Hotkey(settingsValue: value)
            }
        }
    }

    @Test func theErrorNamesTheGrammarItWanted() {
        let message = "\(DictationError.unparseableHotkey("banana"))"

        #expect(message.contains("banana"))
        #expect(message.contains("fn"))
        #expect(message.contains("ctrl+space"))
    }
}

private func settings(
    hotkey: String = "fn",
    whisperBackend: WhisperBackend = .local,
    cleanupBackend: CleanupBackend = .ollama
) -> Settings {
    Settings(
        hotkey: hotkey,
        whisperModelPath: "~/Library/Application Support/Sotto/models/ggml-medium.en.bin",
        whisperBackend: whisperBackend,
        cleanupBackend: cleanupBackend,
        cleanupModel: "qwen3:8b",
        vocabulary: ["pnpm", "Drizzle"],
        appProfiles: ["default": "Fix punctuation."],
        insertionMode: .paste
    )
}

@Suite("Settings to collaborators — the wiring seams", .serialized)
struct DictationWiringTests {
    @Test func ollamaResolvesToTheOllamaBackend() throws {
        let cleaner = try DictationController.cleaner(for: settings(cleanupBackend: .ollama))

        #expect(cleaner is OllamaBackend)
    }

    // `none` is a configured choice, not a failure and not a degradation.
    @Test func aCleanupBackendOfNoneResolvesToNoCleaner() throws {
        #expect(try DictationController.cleaner(for: settings(cleanupBackend: .none)) == nil)
    }

    @Test func aRemoteWhisperBackendIsRefusedRatherThanTranscribedLocally() {
        #expect(throws: DictationError.unsupportedWhisperBackend("groq")) {
            try DictationController(
                settings: settings(whisperBackend: .groq),
                whisperBinaryPath: "/opt/homebrew/bin/whisper-cli",
                onStateChange: { _, _ in }
            )
        }
    }

    @Test func anUnparseableHotkeyStopsTheControllerBeingBuilt() {
        #expect(throws: DictationError.unparseableHotkey("banana")) {
            try DictationController(
                settings: settings(hotkey: "banana"),
                whisperBinaryPath: "/opt/homebrew/bin/whisper-cli",
                onStateChange: { _, _ in }
            )
        }
    }

    @Test func validSettingsBuildAController() throws {
        _ = try DictationController(
            settings: settings(),
            whisperBinaryPath: "/opt/homebrew/bin/whisper-cli",
            onStateChange: { _, _ in }
        )
    }

    // Input Monitoring is not granted to the test binary on this machine. If this starts failing the
    // grant changed: re-run the live-tap work rather than relaxing the assertion.
    @Test func listeningWithoutInputMonitoringSurfacesThePermissionError() {
        #expect(CGPreflightListenEventAccess() == false)

        let log = Log()
        let controller = makeController(
            log: log,
            starts: Counter(),
            stops: Counter(),
            transcripts: [:],
            cleaner: nil
        )

        #expect(throws: HotkeyMonitorError.inputMonitoringDenied) {
            try controller.startListening(onAlarm: { _ in })
        }
    }
}

@Suite("Dictation pipeline — all collaborators stubbed", .serialized)
struct DictationControllerTests {
    @Test func theHappyPathReachesInsertingWithCleanedText() async throws {
        let log = Log()
        let seenSystemPrompt = Counter()
        let controller = makeController(
            log: log,
            starts: Counter(),
            stops: Counter(),
            transcripts: [1: "raw one"],
            cleaner: StubCleaner { transcript, system in
                if system == Prompts.cleanup { _ = seenSystemPrompt.next() }
                log.recordCleanup(transcript)
                return transcript + " cleaned"
            }
        )

        controller.handle(.start)
        controller.handle(.stop)

        #expect(await waitUntil { log.insertedTexts.count == 1 })
        #expect(log.insertedTexts == ["raw one cleaned"])
        #expect(log.states(forJob: 1) == [.recording, .transcribing, .cleaning, .inserting, .done])
        #expect(seenSystemPrompt.count == 1)
    }

    // Decision 3a, the single sanctioned degradation: raw text lands and the pill goes amber.
    @Test func anUnreachableBackendInsertsTheRawTranscriptAndGoesAmber() async throws {
        let log = Log()
        let controller = makeController(
            log: log,
            starts: Counter(),
            stops: Counter(),
            transcripts: [1: "raw one"],
            cleaner: StubCleaner { _, _ in throw CleanupError.backendUnavailable }
        )

        controller.handle(.start)
        controller.handle(.stop)

        #expect(await waitUntil { log.insertedTexts.count == 1 })
        #expect(log.insertedTexts == ["raw one"])
        #expect(log.states(forJob: 1) == [.recording, .transcribing, .cleaning, .inserting, .backendUnavailable])
    }

    // The gate under load: job 2's cleanup genuinely completes first — asserted, not assumed — and
    // the text still lands in the order it was spoken.
    @Test func jobTwoFinishingCleanupFirstStillInsertsSecond() async throws {
        let log = Log()
        let controller = makeController(
            log: log,
            starts: Counter(),
            stops: Counter(),
            transcripts: [1: "one", 2: "two"],
            cleaner: StubCleaner { transcript, _ in
                if transcript == "one" { try await Task.sleep(for: .milliseconds(500)) }
                log.recordCleanup(transcript)
                return transcript + " cleaned"
            }
        )

        controller.handle(.start)
        controller.handle(.stop)
        try await Task.sleep(for: .milliseconds(200))
        controller.handle(.start)
        controller.handle(.stop)

        #expect(await waitUntil { log.insertedTexts.count == 2 })
        #expect(log.cleanupOrder == ["two", "one"], "job 2's cleanup did not actually finish first")
        #expect(log.insertedTexts == ["one cleaned", "two cleaned"])
    }

    @Test func aPressDuringTranscribingStartsASecondRecordingAndBothLand() async throws {
        let log = Log()
        let starts = Counter()
        let controller = makeController(
            log: log,
            starts: starts,
            stops: Counter(),
            transcripts: [1: "one", 2: "two"],
            transcribeDelays: [1: 0.3],
            cleaner: cleanerAppending(" cleaned", log: log)
        )

        controller.handle(.start)
        controller.handle(.stop)
        #expect(await waitUntil { log.startedTranscriptions == ["one"] })
        #expect(log.allChanges.last == Change(job: 1, state: .transcribing))

        controller.handle(.start)
        controller.handle(.stop)

        #expect(starts.count == 2)
        #expect(log.states(forJob: 2).first == .recording)
        #expect(await waitUntil { log.insertedTexts.count == 2 })
        #expect(log.insertedTexts == ["one cleaned", "two cleaned"])
    }

    // The permit is taken before a single sample is recorded, so a password field refuses up front.
    @Test func secureInputRefusesBeforeAnythingIsRecorded() async throws {
        let log = Log()
        let starts = Counter()
        let controller = makeController(
            log: log,
            starts: starts,
            stops: Counter(),
            transcripts: [1: "one"],
            cleaner: cleanerAppending(" cleaned", log: log),
            secureInput: true
        )

        controller.handle(.start)
        controller.handle(.stop)

        #expect(await waitUntil(1) { log.states(forJob: 1) == [.secureInputActive] })
        #expect(starts.count == 0)
        #expect(log.insertedTexts.isEmpty)
    }

    @Test func aDeniedMicrophoneIsVisibleAndRecordsNothing() async throws {
        let log = Log()
        let starts = Counter()
        let controller = makeController(
            log: log,
            starts: starts,
            stops: Counter(),
            transcripts: [1: "one"],
            cleaner: cleanerAppending(" cleaned", log: log),
            microphoneAuthorized: false
        )

        controller.handle(.start)
        controller.handle(.stop)

        #expect(await waitUntil(1) { log.states(forJob: 1) == [.permissionMissing("Microphone")] })
        #expect(starts.count == 0)
        #expect(log.insertedTexts.isEmpty)
    }

    // The 300 ms floor from task 4. The cancelled job must also let the next one through the gate.
    @Test func aReleaseUnderTheFloorInsertsNothingAndDoesNotBlockTheNextJob() async throws {
        let log = Log()
        let controller = makeController(
            log: log,
            starts: Counter(),
            stops: Counter(),
            transcripts: [2: "two"],
            tooShort: [1],
            cleaner: cleanerAppending(" cleaned", log: log)
        )

        controller.handle(.start)
        controller.handle(.stop)
        controller.handle(.start)
        controller.handle(.stop)

        #expect(await waitUntil { log.insertedTexts.count == 1 })
        #expect(log.insertedTexts == ["two cleaned"])
        #expect(log.states(forJob: 1) == [.recording, .cancelled])
    }

    // `catch { insertRaw() }` would turn every bug in the pipeline into a silent raw paste. Only
    // `.backendUnavailable` degrades; anything else is a visible failure that inserts nothing.
    @Test func aCleanupErrorThatIsNotBackendUnavailableNeverPastesRaw() async throws {
        let log = Log()
        let controller = makeController(
            log: log,
            starts: Counter(),
            stops: Counter(),
            transcripts: [1: "one", 2: "two"],
            cleaner: StubCleaner { transcript, _ in
                guard transcript != "one" else { throw CleanupError.requestFailed(status: 500, body: "boom") }
                log.recordCleanup(transcript)
                return transcript + " cleaned"
            }
        )

        controller.handle(.start)
        controller.handle(.stop)
        controller.handle(.start)
        controller.handle(.stop)

        #expect(await waitUntil { log.insertedTexts.count == 1 })
        #expect(log.insertedTexts == ["two cleaned"])
        #expect(log.states(forJob: 1).count == 4)
        guard case .failed = log.states(forJob: 1)[3] else {
            Issue.record("expected job 1 to end in .failed, got \(log.states(forJob: 1))")
            return
        }
    }

    @Test func aTranscriptionFailureIsVisibleAndReleasesTheGate() async throws {
        let log = Log()
        let controller = makeController(
            log: log,
            starts: Counter(),
            stops: Counter(),
            transcripts: [2: "two"],
            cleaner: cleanerAppending(" cleaned", log: log)
        )

        controller.handle(.start)
        controller.handle(.stop)
        controller.handle(.start)
        controller.handle(.stop)

        #expect(await waitUntil { log.insertedTexts.count == 1 })
        #expect(log.insertedTexts == ["two cleaned"])
        guard case .failed = log.states(forJob: 1)[2] else {
            Issue.record("expected job 1 to end in .failed, got \(log.states(forJob: 1))")
            return
        }
    }

    @Test func anInsertionFailureIsVisibleRatherThanSilent() async throws {
        let log = Log()
        let controller = DictationController(
            hotkey: .fn,
            startRecording: {},
            stopRecording: { recordingURL(1) },
            transcribe: { _ in "one" },
            cleaner: cleanerAppending(" cleaned", log: log),
            permitInsertion: permitting(secureInput: false),
            insert: { _, _ in throw InsertionError.pasteboardWriteFailed },
            isMicrophoneAuthorized: { true },
            onStateChange: { log.record(job: $0, state: $1) }
        )

        controller.handle(.start)
        controller.handle(.stop)

        #expect(await waitUntil { log.states(forJob: 1).count == 5 })
        guard case .failed = log.states(forJob: 1)[4] else {
            Issue.record("expected job 1 to end in .failed, got \(log.states(forJob: 1))")
            return
        }
    }

    // Tearing the tap down mid-hold (task 9 disables Sotto that way) loses a release. The abandoned
    // job must be reported and let go, or the sequence gate stalls behind it and every later
    // dictation vanishes with nothing on screen.
    @Test func aStartWhileAHoldIsStillOpenReleasesTheGateRatherThanStallingIt() async throws {
        let log = Log()
        let controller = makeController(
            log: log,
            starts: Counter(),
            stops: Counter(),
            transcripts: [1: "two"],
            cleaner: cleanerAppending(" cleaned", log: log)
        )

        controller.handle(.start)
        controller.handle(.start)
        controller.handle(.stop)

        #expect(await waitUntil { log.insertedTexts.count == 1 })
        #expect(log.insertedTexts == ["two cleaned"])
        guard case .failed = log.states(forJob: 1)[1] else {
            Issue.record("expected job 1 to be abandoned as .failed, got \(log.states(forJob: 1))")
            return
        }
        #expect(log.states(forJob: 2) == [.recording, .transcribing, .cleaning, .inserting, .done])
    }

    // Seam 2's `none` case: no cleaner, no cleaning state, and the transcript inserts as dictated.
    @Test func aNoneBackendInsertsTheTranscriptWithoutACleaningState() async throws {
        let log = Log()
        let controller = makeController(
            log: log,
            starts: Counter(),
            stops: Counter(),
            transcripts: [1: "raw one"],
            cleaner: nil
        )

        controller.handle(.start)
        controller.handle(.stop)

        #expect(await waitUntil { log.insertedTexts.count == 1 })
        #expect(log.insertedTexts == ["raw one"])
        #expect(log.states(forJob: 1) == [.recording, .transcribing, .inserting, .done])
    }
}
