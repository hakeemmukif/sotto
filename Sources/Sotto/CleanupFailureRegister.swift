import Foundation

/// Session-only record of cleanup failures and the latency of the most recent dictation. Nothing
/// here persists across a relaunch: `HistoryStore` is the durable log, and it only ever hears about
/// successful inserts, so this is the only place a failure is remembered at all.
final class CleanupFailureRegister: @unchecked Sendable {
    /// Posted whenever a recorded state changes what `lastFailure`, `failureCount`, or
    /// `lastDictation` would report, so a view model can refresh.
    static let didChange = Notification.Name("com.hakeem.sotto.cleanupFailureRegisterDidChange")

    private let lock = NSLock()
    private var _lastFailure: (date: Date, stage: FailureStage, reason: String)?
    private var _failureCount = 0
    private var _lastDictation: (date: Date, cleanupLatency: TimeInterval?, outcome: DictationState)?
    // Jobs overlap (see DictationController.drain()), so the start of a `.cleaning` phase has to be
    // keyed by sequence rather than assumed to belong to whichever job finishes next.
    private var cleaningStartedAt: [Int: Date] = [:]

    var lastFailure: (date: Date, stage: FailureStage, reason: String)? {
        lock.lock()
        defer { lock.unlock() }
        return _lastFailure
    }

    var failureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _failureCount
    }

    var lastDictation: (date: Date, cleanupLatency: TimeInterval?, outcome: DictationState)? {
        lock.lock()
        defer { lock.unlock() }
        return _lastDictation
    }

    func record(sequence: Int, state: DictationState, at: Date) {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .recording, .transcribing, .inserting:
            return
        case .cleaning:
            cleaningStartedAt[sequence] = at
            return
        case .done, .cancelled, .aborted, .secureInputActive, .backendUnavailable:
            _lastDictation = (at, cleanupLatency(for: sequence, endingAt: at), state)
        case let .permissionMissing(reason):
            // Raised from the same spot in DictationController.beginRecording() as every other
            // `.failed(stage: .recording, ...)`: the permission check runs before startRecording(),
            // so it never got further than the recording phase either.
            _lastFailure = (at, .recording, reason)
            _failureCount += 1
            _lastDictation = (at, cleanupLatency(for: sequence, endingAt: at), state)
        case let .failed(stage, reason):
            _lastFailure = (at, stage, reason)
            _failureCount += 1
            _lastDictation = (at, cleanupLatency(for: sequence, endingAt: at), state)
        }

        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Clears the remembered failure, for when a later dictation succeeds. `lastDictation` is left
    /// alone: it is a latency signal, not a failure signal.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        _lastFailure = nil
        _failureCount = 0
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func cleanupLatency(for sequence: Int, endingAt at: Date) -> TimeInterval? {
        guard let started = cleaningStartedAt.removeValue(forKey: sequence) else { return nil }
        return at.timeIntervalSince(started)
    }
}
