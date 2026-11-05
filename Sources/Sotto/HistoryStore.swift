import Foundation

struct DictationRecord: Codable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let raw: String
    let cleaned: String
    let bundleID: String?
    let durationMs: Int

    init(id: UUID, timestamp: Date, raw: String, cleaned: String, bundleID: String?, durationMs: Int) {
        self.id = id
        // .iso8601 stores whole seconds, so the record must already be whole seconds to equal its reload.
        self.timestamp = Date(timeIntervalSinceReferenceDate: timestamp.timeIntervalSinceReferenceDate.rounded())
        self.raw = raw
        self.cleaned = cleaned
        self.bundleID = bundleID
        self.durationMs = durationMs
    }

    // Not stored: a word count that disagrees with the text it counts is worse than no count.
    var wordCount: Int {
        cleaned.split(whereSeparator: \.isWhitespace).count
    }
}

/// Append-only log of every dictation, one JSON line per record.
///
/// JSONL rather than SQLite because the only reads are "load them all" and the only writes are
/// "add one" and "rewrite without some". At a hundred dictations a day a year of records is a few
/// megabytes, which loads faster than opening a database connection.
final class HistoryStore: @unchecked Sendable {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Sotto/history.jsonl")

    /// Posted after a record reaches disk, so an open window shows a dictation as it lands rather
    /// than only when it is next opened.
    static let didAppend = Notification.Name("com.hakeem.sotto.historyDidAppend")

    private let url: URL
    private let retentionDays: Int
    private let lock = NSLock()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(url: URL = HistoryStore.defaultURL, retentionDays: Int = 90) {
        self.url = url
        self.retentionDays = retentionDays
    }

    /// Newest first. A line that does not decode is skipped: a half-written line is the expected
    /// cost of append-only plus a crash, and it must not cost the user the rest of the history.
    func records() -> [DictationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    func append(_ record: DictationRecord) {
        lock.lock()
        defer { lock.unlock() }

        guard var line = try? Self.encoder.encode(record) else {
            NSLog("Sotto: history append failed to encode record \(record.id)")
            return
        }
        line.append(0x0A)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? line.write(to: url)
        }

        NotificationCenter.default.post(name: Self.didAppend, object: nil)
    }

    func delete(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        rewrite(load().filter { $0.id != id })
    }

    /// Drops records older than the retention window. Called once at launch, not per append.
    func trim(now: Date) {
        lock.lock()
        defer { lock.unlock() }

        let cutoff = now.addingTimeInterval(TimeInterval(-retentionDays) * 86400)
        let kept = load().filter { $0.timestamp >= cutoff }
        rewrite(kept)
    }

    private func load() -> [DictationRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }

        return data
            .split(separator: 0x0A)
            .compactMap { try? Self.decoder.decode(DictationRecord.self, from: Data($0)) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private func rewrite(_ records: [DictationRecord]) {
        var data = Data()
        for record in records.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard var line = try? Self.encoder.encode(record) else { continue }
            line.append(0x0A)
            data.append(line)
        }
        try? data.write(to: url, options: .atomic)
    }
}
