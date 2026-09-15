import AppKit
import AVFoundation
import Carbon
import CoreGraphics
import Foundation

enum DictationError: Error, Equatable, CustomStringConvertible {
    case unparseableHotkey(String)
    case unsupportedWhisperBackend(String)

    var description: String {
        switch self {
        case let .unparseableHotkey(value):
            "settings.json has hotkey \"\(value)\". Write \"fn\", a modifier combination such as \"ctrl+opt+cmd\", or a chord such as \"ctrl+space\" built from cmd/ctrl/opt/shift and one of space, escape, f13–f19."
        case let .unsupportedWhisperBackend(value):
            "settings.json has whisperBackend \"\(value)\". Sotto transcribes locally through whisper-cli; set it to \"local\"."
        }
    }
}

// Exists for routing a failure to its remedy, not for display — the pill still shows only `reason`.
/// Which phase of a dictation failed. This is for routing, not display: a cleanup failure is fixed
/// in the settings panel and a missing permission is fixed in System Settings, and the pill needs to
/// know which without parsing the reason string for clues.
enum FailureStage: Equatable, Sendable {
    case launch, recording, transcription, cleanup, insertion
}

/// What the pill renders. Every state a job can end in is here, because an error that leaves nothing
/// on screen is indistinguishable from Sotto not working.
enum DictationState: Equatable, Sendable {
    case recording
    case transcribing
    case cleaning
    case inserting
    case done
    case cancelled
    // Escape during a hold. The audio is discarded before transcription, so this is a user decision
    // rather than a failure, and the pill hides just as it does for .done.
    case aborted
    case secureInputActive
    // Decision 3a, the only sanctioned degradation: the cleanup backend was unreachable, the raw
    // transcript was inserted anyway, and the pill goes amber.
    case backendUnavailable
    case permissionMissing(String)
    case failed(stage: FailureStage, reason: String)
}

extension Hotkey {
    private static let modifierFlags: [String: CGEventFlags] = [
        "cmd": .maskCommand,
        "ctrl": .maskControl,
        "opt": .maskAlternate,
        "shift": .maskShift,
    ]

    private static let keyCodes: [String: Int64] = [
        "space": Int64(kVK_Space),
        "escape": Int64(kVK_Escape),
        "f13": Int64(kVK_F13),
        "f14": Int64(kVK_F14),
        "f15": Int64(kVK_F15),
        "f16": Int64(kVK_F16),
        "f17": Int64(kVK_F17),
        "f18": Int64(kVK_F18),
        "f19": Int64(kVK_F19),
    ]

    init(settingsValue: String) throws {
        // omittingEmptySubsequences: false so "ctrl+" keeps its empty tail and fails parsing
        // instead of reading as a bare modifier when the user plainly meant an unfinished chord.
        let parts = settingsValue
            .lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if parts == ["fn"] {
            self = .fn
            return
        }
        // Modifiers only — held like `fn`, for keyboards without an fn key. Checked before the
        // chord path, where modifier names alone would otherwise read as a missing key.
        if !parts.isEmpty, parts.allSatisfy({ Hotkey.modifierFlags[$0] != nil }) {
            self = .modifier(CGEventFlags(parts.compactMap { Hotkey.modifierFlags[$0] }))
            return
        }
        guard let keyName = parts.last, let keyCode = Hotkey.keyCodes[keyName] else {
            throw DictationError.unparseableHotkey(settingsValue)
        }
        var modifiers: CGEventFlags = []
        for name in parts.dropLast() {
            guard let flag = Hotkey.modifierFlags[name] else {
                throw DictationError.unparseableHotkey(settingsValue)
            }
            modifiers.insert(flag)
        }
        self = .chord(keyCode: keyCode, modifiers: modifiers)
    }
}

/// Wraps a real `Cleaner` to adapt the cleanup prompt to whatever app is frontmost when cleanup
/// runs, so `run()` and the designated init stay untouched: they still just call
/// `cleaner.clean(transcript, system: Prompts.cleanup)`.
private struct ProfiledCleaner: Cleaner {
    let underlying: Cleaner
    let appProfiles: [String: String]
    let vocabulary: String?

    func clean(_ transcript: String, system: String) async throws -> String {
        let profile = try AppProfiles.profile(
            for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            in: appProfiles
        )
        // The vocabulary steers whisper *and* the cleanup pass: knowing "Drizzle" is a proper noun
        // stops the model correcting it back to "drizzle" after whisper got it right.
        var system = system + "\n\n" + profile
        if let vocabulary {
            system += "\n\nThese terms are spelled correctly, leave them as they are: \(vocabulary)"
        }
        return try await underlying.clean(transcript, system: system)
    }
}

/// Unchecked because every piece of mutable state below lives behind `lock`, and the two queues
/// partition the rest: `jobQueue` runs transcription and cleanup concurrently, `insertionQueue` is
/// serial so only one insertion is ever in flight.
final class DictationController: @unchecked Sendable {
    /// What the dictation produced, beside the text that gets inserted. Carried through the
    /// insertion queue so the history record describes the dictation, not the moment it landed.
    private struct Origin {
        let transcript: String
        let startedAt: Date
        let durationMs: Int
        let bundleID: String?
    }

    private enum Insertion {
        case text(String, permit: InsertionPermit, raw: Bool, origin: Origin)
        case nothing
    }

    private let hotkey: Hotkey
    private let startRecording: @Sendable () throws -> Void
    private let stopRecording: @Sendable () throws -> URL?
    private let transcribe: @Sendable (URL) throws -> String
    private let cleaner: Cleaner?
    private let permitInsertion: @Sendable () throws -> InsertionPermit
    private let insert: @Sendable (String, InsertionPermit) throws -> Void
    private let isMicrophoneAuthorized: @Sendable () -> Bool
    private let onStateChange: @Sendable (Int, DictationState) -> Void
    private let frontmostBundleID: @Sendable () -> String?
    private let recordHistory: @Sendable (DictationRecord) -> Void

    private let jobQueue = DispatchQueue(label: "com.hakeem.sotto.jobs", attributes: .concurrent)
    private let insertionQueue = DispatchQueue(label: "com.hakeem.sotto.insertion")

    private let lock = NSLock()
    private var nextSequence = 1
    private var holding: (sequence: Int, permit: InsertionPermit, startedAt: Date, bundleID: String?)?
    private var pending: [Int: Insertion] = [:]
    private var nextToInsert = 1
    private var monitor: HotkeyMonitor?

    init(
        hotkey: Hotkey,
        startRecording: @escaping @Sendable () throws -> Void,
        stopRecording: @escaping @Sendable () throws -> URL?,
        transcribe: @escaping @Sendable (URL) throws -> String,
        cleaner: Cleaner?,
        permitInsertion: @escaping @Sendable () throws -> InsertionPermit,
        insert: @escaping @Sendable (String, InsertionPermit) throws -> Void,
        isMicrophoneAuthorized: @escaping @Sendable () -> Bool,
        onStateChange: @escaping @Sendable (Int, DictationState) -> Void,
        frontmostBundleID: @escaping @Sendable () -> String? = { nil },
        recordHistory: @escaping @Sendable (DictationRecord) -> Void = { _ in }
    ) {
        self.hotkey = hotkey
        self.startRecording = startRecording
        self.stopRecording = stopRecording
        self.transcribe = transcribe
        self.cleaner = cleaner
        self.permitInsertion = permitInsertion
        self.insert = insert
        self.isMicrophoneAuthorized = isMicrophoneAuthorized
        self.onStateChange = onStateChange
        self.frontmostBundleID = frontmostBundleID
        self.recordHistory = recordHistory
    }

    convenience init(
        settings: Settings,
        whisperBinaryPath: String,
        history: History = History(),
        store: HistoryStore? = nil,
        onStateChange: @escaping @Sendable (Int, DictationState) -> Void
    ) throws {
        guard settings.whisperBackend == .local else {
            throw DictationError.unsupportedWhisperBackend(settings.whisperBackend.rawValue)
        }
        let hotkey = try Hotkey(settingsValue: settings.hotkey)
        let vocabularyPrompt = try Vocabulary.whisperPrompt(settings.vocabulary)
        let cleaner = try DictationController.cleaner(for: settings).map {
            ProfiledCleaner(
                underlying: $0,
                appProfiles: settings.appProfiles,
                vocabulary: vocabularyPrompt
            ) as Cleaner
        }
        let transcriber = Transcriber(binaryPath: whisperBinaryPath, modelPath: settings.whisperModelPath)
        let inserter = TextInserter(mode: settings.insertionMode)
        // One recorder, because you can only speak one dictation at a time. `start` and `stop` reach
        // it only from the hotkey delivery thread, one after the other, never concurrently.
        nonisolated(unsafe) let recorder = AudioRecorder()

        self.init(
            hotkey: hotkey,
            startRecording: { try recorder.start() },
            stopRecording: { try recorder.stop() },
            transcribe: { try transcriber.transcribe($0, vocabularyPrompt: vocabularyPrompt) },
            cleaner: cleaner,
            permitInsertion: { try inserter.permitInsertion() },
            insert: { try inserter.insert($0, permit: $1) },
            isMicrophoneAuthorized: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
            onStateChange: onStateChange,
            frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            // The ring buffer still backs the menu. The store is what survives a quit.
            recordHistory: { record in
                history.insert(record.cleaned)
                store?.append(record)
            }
        )
    }

    static func cleaner(for settings: Settings) throws -> Cleaner? {
        switch settings.cleanupBackend {
        case .ollama:
            return OllamaBackend(model: settings.cleanupModel)
        case .groq:
            return try OpenAICompatibleBackend.groq(model: settings.cleanupModel)
        case .openai:
            return try OpenAICompatibleBackend.openAI(model: settings.cleanupModel)
        case .none:
            // Not a failure and not a degradation: the user asked for no cleanup, so the transcript
            // is inserted exactly as dictated and no job ever reports `.backendUnavailable`.
            return nil
        }
    }

    func startListening(onAlarm: @escaping @Sendable (HotkeyAlarm) -> Void) throws {
        let monitor = HotkeyMonitor(
            hotkey: hotkey,
            onEvent: { [weak self] event in self?.handle(event) },
            onAlarm: onAlarm
        )
        try monitor.start()
        lock.lock()
        self.monitor = monitor
        lock.unlock()
    }

    func stopListening() {
        lock.lock()
        let monitor = self.monitor
        self.monitor = nil
        lock.unlock()
        monitor?.stop()
    }

    func handle(_ event: HotkeyEvent) {
        switch event {
        case .start: beginRecording()
        case .stop: finishRecording()
        case .abort: abortRecording()
        }
    }

    private func beginRecording() {
        lock.lock()
        let sequence = nextSequence
        nextSequence += 1
        let abandoned = holding
        holding = nil
        lock.unlock()

        // A start arriving while a hold is still open means that hold's release was lost — the tap
        // was torn down mid-hold, say. It can never deposit, and the gate would stall behind it.
        if let abandoned {
            onStateChange(abandoned.sequence, .failed(stage: .recording, reason: "the hold ended without a release"))
            deposit(abandoned.sequence, .nothing)
        }

        do {
            // The permit is taken before a single sample is recorded. That ordering is the whole
            // point of `InsertionPermit`: in a password field the user is refused now, rather than
            // after twenty seconds of speech that could never have been pasted.
            let permit = try permitInsertion()
            guard isMicrophoneAuthorized() else {
                onStateChange(sequence, .permissionMissing("Microphone"))
                deposit(sequence, .nothing)
                return
            }
            try startRecording()
            lock.lock()
            holding = (sequence, permit, Date(), frontmostBundleID())
            lock.unlock()
            onStateChange(sequence, .recording)
        } catch InsertionError.secureInputActive {
            onStateChange(sequence, .secureInputActive)
            deposit(sequence, .nothing)
        } catch {
            // `.recording` names the phase of work, not a state this job reached: it fails here
            // precisely because `startRecording` never got far enough to emit `.recording`.
            // `.launch` is reserved for `startListening` failing at app start, which has a different
            // remedy — the app is not listening at all, rather than one dictation not beginning.
            onStateChange(sequence, .failed(stage: .recording, reason: "\(error)"))
            deposit(sequence, .nothing)
        }
    }

    private func finishRecording() {
        lock.lock()
        let job = holding
        holding = nil
        lock.unlock()
        guard let (sequence, permit, startedAt, bundleID) = job else { return }

        do {
            guard let wav = try stopRecording() else {
                onStateChange(sequence, .cancelled)
                deposit(sequence, .nothing)
                return
            }
            // Measured here, not at insertion: WPM must describe how fast the user spoke, and
            // transcription plus cleanup add seconds that have nothing to do with speaking.
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            onStateChange(sequence, .transcribing)
            jobQueue.async { [self] in
                run(
                    sequence: sequence, permit: permit, wav: wav,
                    startedAt: startedAt, durationMs: durationMs, bundleID: bundleID
                )
            }
        } catch {
            onStateChange(sequence, .failed(stage: .recording, reason: "\(error)"))
            deposit(sequence, .nothing)
        }
    }

    private func abortRecording() {
        lock.lock()
        let job = holding
        holding = nil
        lock.unlock()
        guard let (sequence, _, _, _) = job else { return }

        // Stop the mic and throw the audio away. `stopRecording()` can return nil (a clip under
        // AudioRecorder.minimumDuration) or throw; neither changes the outcome, because nothing is
        // transcribed either way. `run()` normally deletes the wav in its `defer` and never runs on
        // this path, so the delete happens here or the temp file leaks.
        let wav = try? stopRecording()
        if let wav { try? FileManager.default.removeItem(at: wav) }

        onStateChange(sequence, .aborted)
        deposit(sequence, .nothing)
    }

    private func run(
        sequence: Int, permit: InsertionPermit, wav: URL,
        startedAt: Date, durationMs: Int, bundleID: String?
    ) {
        let transcript: String
        do {
            defer { try? FileManager.default.removeItem(at: wav) }
            transcript = try transcribe(wav)
        } catch {
            onStateChange(sequence, .failed(stage: .transcription, reason: "\(error)"))
            deposit(sequence, .nothing)
            return
        }

        let origin = Origin(
            transcript: transcript, startedAt: startedAt, durationMs: durationMs, bundleID: bundleID
        )

        guard let cleaner else {
            deposit(sequence, .text(transcript, permit: permit, raw: false, origin: origin))
            return
        }

        onStateChange(sequence, .cleaning)
        Task { [self] in
            do {
                let cleaned = try await cleaner.clean(transcript, system: Prompts.cleanup)
                deposit(sequence, .text(cleaned, permit: permit, raw: false, origin: origin))
            } catch CleanupError.backendUnavailable {
                deposit(sequence, .text(transcript, permit: permit, raw: true, origin: origin))
            } catch {
                onStateChange(sequence, .failed(stage: .cleanup, reason: "\(error)"))
                deposit(sequence, .nothing)
            }
        }
    }

    private func deposit(_ sequence: Int, _ insertion: Insertion) {
        lock.lock()
        pending[sequence] = insertion
        lock.unlock()
        insertionQueue.async { [self] in drain() }
    }

    /// The sequence gate. Jobs overlap through transcription and cleanup, so job 2 can be ready
    /// first — a shorter clip, or a backend that answered faster. Insertion only ever takes the
    /// lowest outstanding sequence number, so text lands in the order it was spoken. Every job
    /// deposits exactly once, including the cancelled and failed ones, or the gate would never
    /// advance past them.
    private func drain() {
        while true {
            lock.lock()
            guard let insertion = pending.removeValue(forKey: nextToInsert) else {
                lock.unlock()
                return
            }
            let sequence = nextToInsert
            nextToInsert += 1
            lock.unlock()

            guard case let .text(text, permit, raw, origin) = insertion else { continue }

            onStateChange(sequence, .inserting)
            do {
                try insert(text, permit)
                recordHistory(DictationRecord(
                    id: UUID(),
                    timestamp: origin.startedAt,
                    raw: origin.transcript,
                    cleaned: text,
                    bundleID: origin.bundleID,
                    durationMs: origin.durationMs
                ))
                onStateChange(sequence, raw ? .backendUnavailable : .done)
            } catch InsertionError.secureInputActive {
                onStateChange(sequence, .secureInputActive)
            } catch {
                onStateChange(sequence, .failed(stage: .insertion, reason: "\(error)"))
            }
        }
    }
}
