import Foundation
import Testing
@testable import Sotto

@Test func inserting25EntriesRetainsExactlyLast20InOrder() {
    let history = History()

    for i in 1 ... 25 {
        history.insert("transcript \(i)")
    }

    let transcripts = history.transcripts

    #expect(transcripts.count == 20)
    #expect(transcripts[0] == "transcript 6")
    #expect(transcripts[1] == "transcript 7")
    #expect(transcripts[19] == "transcript 25")
}

@Test func historyStartsEmpty() {
    let history = History()

    #expect(history.transcripts.isEmpty)
}

@Test func historyPreservesOrderWithFewerThan20Entries() {
    let history = History()

    for i in 1 ... 10 {
        history.insert("transcript \(i)")
    }

    let transcripts = history.transcripts

    #expect(transcripts.count == 10)
    #expect(transcripts[0] == "transcript 1")
    #expect(transcripts[9] == "transcript 10")
}

@Test func noFileCreatedUnderLibrary() throws {
    let libraryPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")

    // Snapshot before
    let beforeContents = try FileManager.default.contentsOfDirectory(atPath: libraryPath.path)
    let beforeSet = Set(beforeContents)

    // Run history
    let history = History()
    for i in 1 ... 25 {
        history.insert("transcript \(i)")
    }
    _ = history.transcripts

    // Snapshot after
    let afterContents = try FileManager.default.contentsOfDirectory(atPath: libraryPath.path)
    let afterSet = Set(afterContents)

    #expect(beforeSet == afterSet, "Library directory was modified")
}

@Test func concurrentInsertionsAreThreadSafe() async {
    let history = History()

    await withTaskGroup(of: Void.self) { group in
        for threadIndex in 0 ..< 10 {
            group.addTask {
                for itemIndex in 0 ..< 10 {
                    history.insert("thread \(threadIndex) item \(itemIndex)")
                }
            }
        }
    }

    let transcripts = history.transcripts

    #expect(transcripts.count == 20)
    #expect(!transcripts.contains { $0.isEmpty })
}
