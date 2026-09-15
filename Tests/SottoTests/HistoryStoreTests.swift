import Foundation
import Testing
@testable import Sotto

@Suite("HistoryStore — the on-disk dictation log")
struct HistoryStoreTests {
    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sotto-history-\(UUID().uuidString).jsonl")
    }

    private func record(
        _ cleaned: String,
        daysAgo: Int = 0,
        bundleID: String? = "com.apple.Terminal",
        durationMs: Int = 5000
    ) -> DictationRecord {
        DictationRecord(
            id: UUID(),
            timestamp: Date().addingTimeInterval(TimeInterval(-daysAgo) * 86400),
            raw: "raw \(cleaned)",
            cleaned: cleaned,
            bundleID: bundleID,
            durationMs: durationMs
        )
    }

    @Test func aMissingFileLoadsAsNoRecords() throws {
        let store = HistoryStore(url: scratchURL())

        #expect(store.records().isEmpty)
    }

    @Test func anAppendedRecordSurvivesAReload() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let written = record("Ship the history window.")

        HistoryStore(url: url).append(written)

        let read = HistoryStore(url: url).records()
        #expect(read.count == 1)
        #expect(read.first == written)
    }

    @Test func recordsComeBackNewestFirst() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        store.append(record("older", daysAgo: 2))
        store.append(record("newer", daysAgo: 1))

        #expect(store.records().map(\.cleaned) == ["newer", "older"])
    }

    // A half-written line is the expected cost of append-only plus a crash. One bad line must not
    // cost the user the whole history.
    @Test func aCorruptLineIsSkippedAndTheRestSurvive() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        store.append(record("first", daysAgo: 2))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"not-a-record\"\n".utf8))
        try handle.close()
        store.append(record("second", daysAgo: 1))

        #expect(store.records().map(\.cleaned) == ["second", "first"])
    }

    @Test func aDeletedRecordDoesNotComeBack() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        let doomed = record("delete me")
        store.append(record("keep me"))
        store.append(doomed)

        store.delete(id: doomed.id)

        #expect(HistoryStore(url: url).records().map(\.cleaned) == ["keep me"])
    }

    @Test func trimDropsRecordsPastTheRetentionWindow() throws {
        let url = scratchURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url, retentionDays: 90)
        store.append(record("ancient", daysAgo: 100))
        store.append(record("inside the window", daysAgo: 89))

        store.trim(now: Date())

        #expect(HistoryStore(url: url).records().map(\.cleaned) == ["inside the window"])
    }

    @Test func wordCountComesFromTheCleanedText() throws {
        #expect(record("one two  three").wordCount == 3)
    }
}
