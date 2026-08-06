import Foundation

final class History: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = Array(repeating: "", count: 20)
    private var nextIndex = 0
    private var count = 0

    func insert(_ transcript: String) {
        lock.lock()
        defer { lock.unlock() }

        buffer[nextIndex] = transcript
        nextIndex = (nextIndex + 1) % 20
        count = min(count + 1, 20)
    }

    var transcripts: [String] {
        lock.lock()
        defer { lock.unlock() }

        if count < 20 {
            return Array(buffer[0 ..< count])
        }

        return Array(buffer[nextIndex...]) + Array(buffer[0 ..< nextIndex])
    }
}
