import Foundation
import Testing
@testable import Sotto

private final class ReceivedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var current: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("CleanupFailureRegister — cleanup failures and latency, offline")
struct CleanupFailureRegisterTests {
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aCleanupFailureSetsLastFailureAndIncrementsCount() {
        let register = CleanupFailureRegister()

        register.record(sequence: 1, state: .failed(stage: .cleanup, reason: "boom"), at: Self.epoch)

        #expect(register.lastFailure?.stage == .cleanup)
        #expect(register.lastFailure?.reason == "boom")
        #expect(register.lastFailure?.date == Self.epoch)
        #expect(register.failureCount == 1)
    }

    @Test func aSuccessfulJobDoesNotIncrementAndUpdatesLastDictation() {
        let register = CleanupFailureRegister()

        register.record(sequence: 1, state: .done, at: Self.epoch)

        #expect(register.failureCount == 0)
        #expect(register.lastFailure == nil)
        #expect(register.lastDictation?.outcome == .done)
        #expect(register.lastDictation?.date == Self.epoch)
    }

    @Test func cleaningThenBackendUnavailableProducesTheElapsedLatency() {
        let register = CleanupFailureRegister()
        let start = Self.epoch

        register.record(sequence: 1, state: .cleaning, at: start)
        register.record(sequence: 1, state: .backendUnavailable, at: start.addingTimeInterval(20))

        #expect(register.lastDictation?.cleanupLatency == 20)
        #expect(register.lastDictation?.outcome == .backendUnavailable)
    }

    @Test func aJobThatNeverEnteredCleaningHasNilLatencyNotZero() {
        let register = CleanupFailureRegister()
        let start = Self.epoch

        register.record(sequence: 1, state: .recording, at: start)
        register.record(sequence: 1, state: .transcribing, at: start.addingTimeInterval(1))
        register.record(sequence: 1, state: .failed(stage: .transcription, reason: "no audio"), at: start.addingTimeInterval(2))

        #expect(register.lastDictation?.cleanupLatency == nil)
    }

    @Test func twoInterleavedJobsEachGetTheirOwnLatency() {
        let register = CleanupFailureRegister()
        let start = Self.epoch

        register.record(sequence: 1, state: .cleaning, at: start)
        register.record(sequence: 2, state: .cleaning, at: start.addingTimeInterval(1))
        register.record(sequence: 2, state: .done, at: start.addingTimeInterval(4))

        #expect(register.lastDictation?.outcome == .done)
        #expect(register.lastDictation?.cleanupLatency == 3)

        register.record(sequence: 1, state: .done, at: start.addingTimeInterval(10))

        #expect(register.lastDictation?.outcome == .done)
        #expect(register.lastDictation?.cleanupLatency == 10)
    }

    @Test func failureCountAccumulatesAndLastFailureIsTheMostRecent() {
        let register = CleanupFailureRegister()
        let start = Self.epoch

        register.record(sequence: 1, state: .failed(stage: .cleanup, reason: "first"), at: start)
        register.record(sequence: 2, state: .failed(stage: .insertion, reason: "second"), at: start.addingTimeInterval(5))
        register.record(sequence: 3, state: .permissionMissing("Microphone"), at: start.addingTimeInterval(10))

        #expect(register.failureCount == 3)
        #expect(register.lastFailure?.reason == "Microphone")
        #expect(register.lastFailure?.stage == .recording)
        #expect(register.lastFailure?.date == start.addingTimeInterval(10))
    }

    @Test func recordingAChangePostsTheNotification() {
        let register = CleanupFailureRegister()
        let received = ReceivedFlag()
        let observer = NotificationCenter.default.addObserver(
            forName: CleanupFailureRegister.didChange, object: nil, queue: nil
        ) { _ in received.set() }
        defer { NotificationCenter.default.removeObserver(observer) }

        register.record(sequence: 1, state: .done, at: Self.epoch)

        #expect(received.current)
    }
}
