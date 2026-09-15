import Foundation

// Lets the settings panel swap the cleanup model at runtime without rebuilding
// `DictationController`. A job snapshots the cleaner at the moment its `clean` call begins and
// completes with that cleaner regardless of any later `replace` — two concurrent jobs may run
// against different cleaners, but each one uses exactly one, start to finish.
final class CleanerSlot: Cleaner, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Cleaner
    private var currentModel: String

    init(_ cleaner: Cleaner, model: String) {
        current = cleaner
        currentModel = model
    }

    var model: String {
        lock.lock()
        defer { lock.unlock() }
        return currentModel
    }

    func replace(_ cleaner: Cleaner, model: String) {
        lock.lock()
        current = cleaner
        currentModel = model
        lock.unlock()
    }

    func clean(_ transcript: String, system: String) async throws -> String {
        // The lock must not be held across the `await`: a swap during a long cleanup would either
        // deadlock the swap or serialize every concurrent job behind whichever one is slowest.
        // `lock()`/`unlock()` are unavailable in async functions in Swift 6.3 for that same reason,
        // so the snapshot has to happen inside `withLock`, not around it.
        let cleaner = lock.withLock { current }
        return try await cleaner.clean(transcript, system: system)
    }
}
