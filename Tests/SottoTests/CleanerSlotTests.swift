import Foundation
import Testing
@testable import Sotto

private struct StubCleaner: Cleaner {
    let result: String

    func clean(_ transcript: String, system: String) async throws -> String {
        result
    }
}

// Parks `clean()` on a continuation so a test can observe "in flight" and control exactly when it
// completes, which is the only way to prove a `replace()` mid-call doesn't retarget that call.
private final class GateCleaner: Cleaner, @unchecked Sendable {
    let result: String
    private let lock = NSLock()
    private let suspended = DispatchSemaphore(value: 0)
    private var waiting: CheckedContinuation<Void, Never>?

    init(result: String) {
        self.result = result
    }

    func clean(_ transcript: String, system: String) async throws -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            waiting = continuation
            lock.unlock()
            suspended.signal()
        }
        return result
    }

    func waitUntilSuspended(timeout: TimeInterval = 2.0) -> Bool {
        suspended.wait(timeout: .now() + timeout) == .success
    }

    func resume() {
        lock.lock()
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume()
    }
}

@Suite("CleanerSlot")
struct CleanerSlotTests {
    @Test func theInFlightCallFinishesWithTheCleanerItStartedWith() async throws {
        let old = GateCleaner(result: "old")
        let new = StubCleaner(result: "new")
        let slot = CleanerSlot(old, model: "old-model")

        let inFlight = Task { try await slot.clean("t", system: "s") }
        #expect(old.waitUntilSuspended())

        slot.replace(new, model: "new-model")
        old.resume()

        #expect(try await inFlight.value == "old")
    }

    @Test func theNextCallAfterReplaceUsesTheNewCleaner() async throws {
        let old = StubCleaner(result: "old")
        let new = StubCleaner(result: "new")
        let slot = CleanerSlot(old, model: "old-model")

        slot.replace(new, model: "new-model")

        #expect(try await slot.clean("t", system: "s") == "new")
    }

    @Test func fiftyConcurrentCallsAcrossOneReplaceEachGetExactlyOneCleaner() async throws {
        let old = StubCleaner(result: "old")
        let new = StubCleaner(result: "new")
        let slot = CleanerSlot(old, model: "old-model")

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0 ..< 50 {
                group.addTask {
                    if i == 25 { slot.replace(new, model: "new-model") }
                    return try await slot.clean("t", system: "s")
                }
            }
            var collected: [String] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(results.count == 50)
        #expect(results.allSatisfy { $0 == "old" || $0 == "new" })
    }

    @Test func modelReflectsTheCurrentlyHeldCleanerBeforeAndAfterASwap() {
        let old = StubCleaner(result: "old")
        let new = StubCleaner(result: "new")
        let slot = CleanerSlot(old, model: "old-model")

        #expect(slot.model == "old-model")

        slot.replace(new, model: "new-model")

        #expect(slot.model == "new-model")
    }
}
