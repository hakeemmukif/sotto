import AppKit
import Combine
import Foundation
import SwiftUI

struct HistoryDay: Identifiable {
    let id: Date
    let label: String
    let records: [DictationRecord]
}

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var query: String = "" { didSet { recomputeGroups() } }
    @Published var appFilter: String? { didSet { recomputeGroups() } }
    @Published var showRaw: Bool = false
    @Published var newestFirst: Bool = true { didSet { recomputeGroups() } }
    @Published var selectedID: UUID?
    @Published private(set) var groups: [HistoryDay] = []

    private let store: HistoryStore
    private var allRecords: [DictationRecord] = []
    private var appNameCache: [String: String] = [:]
    private var appendObserver: AnyCancellable?

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    init(store: HistoryStore) {
        self.store = store
        reload()

        // The append happens on the insertion queue, so the reload has to be hopped to the main
        // actor before it touches published state.
        appendObserver = NotificationCenter.default
            .publisher(for: HistoryStore.didAppend)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
    }

    func reload() {
        allRecords = store.records()
        recomputeGroups()
    }

    func delete(_ id: UUID) {
        store.delete(id: id)
        reload()
    }

    func copyToPasteboard(_ id: UUID) {
        guard let record = allRecords.first(where: { $0.id == id }) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(displayText(for: record), forType: .string)
    }

    func displayText(for record: DictationRecord) -> String {
        showRaw ? record.raw : record.cleaned
    }

    func appName(for record: DictationRecord) -> String {
        appDisplayName(for: record.bundleID)
    }

    var totalWords: Int {
        allRecords.reduce(0) { $0 + $1.wordCount }
    }

    var averageWPM: Int {
        let totalMs = allRecords.reduce(0) { $0 + $1.durationMs }
        guard totalMs > 0 else { return 0 }
        let minutes = Double(totalMs) / 60_000
        return Int((Double(totalWords) / minutes).rounded())
    }

    var streakDays: Int {
        let calendar = Calendar.current
        let days = Set(allRecords.map { calendar.startOfDay(for: $0.timestamp) })
        return Self.computeStreak(days: days, calendar: calendar)
    }

    var totalCount: Int {
        allRecords.count
    }

    var shownCount: Int {
        groups.reduce(0) { $0 + $1.records.count }
    }

    var availableApps: [(bundleID: String, name: String)] {
        let ids = Set(allRecords.compactMap(\.bundleID))
        return ids
            .map { (bundleID: $0, name: appDisplayName(for: $0)) }
            .sorted { $0.name < $1.name }
    }

    private func recomputeGroups() {
        let calendar = Calendar.current
        let filtered = allRecords.filter(matchesFilters)
        let bucketed = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.timestamp) }
        let dayKeys = bucketed.keys.sorted(by: newestFirst ? (>) : (<))

        groups = dayKeys.map { day in
            let dayRecords = bucketed[day]!.sorted {
                newestFirst ? $0.timestamp > $1.timestamp : $0.timestamp < $1.timestamp
            }
            return HistoryDay(id: day, label: Self.label(for: day, calendar: calendar), records: dayRecords)
        }
    }

    private func matchesFilters(_ record: DictationRecord) -> Bool {
        if let appFilter, record.bundleID != appFilter { return false }
        guard !query.isEmpty else { return true }
        return record.raw.localizedCaseInsensitiveContains(query)
            || record.cleaned.localizedCaseInsensitiveContains(query)
    }

    private static func label(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        return weekdayFormatter.string(from: day).uppercased()
    }

    // Today is still in progress when this runs, so a day with no entry yet must not
    // zero out a streak that is still alive as of yesterday.
    private static func computeStreak(days: Set<Date>, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }

        var cursor = calendar.startOfDay(for: Date())
        if !days.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
            guard days.contains(cursor) else { return 0 }
        }

        var streak = 0
        while days.contains(cursor) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return streak
    }

    private func appDisplayName(for bundleID: String?) -> String {
        guard let bundleID else { return "UNKNOWN" }
        if let cached = appNameCache[bundleID] { return cached }
        let name = Self.resolveAppName(bundleID: bundleID)
        appNameCache[bundleID] = name
        return name
    }

    // `FileManager.displayName` returns "Mail.app" whenever the user has Finder's extension hiding
    // turned off, so the bundle's own display name is read first. An app that is not installed
    // cannot be resolved at all, and degrades to the last component of its bundle id.
    private static func resolveAppName(bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            if let bundle = Bundle(url: url) {
                for key in ["CFBundleDisplayName", "CFBundleName"] {
                    if let name = bundle.object(forInfoDictionaryKey: key) as? String, !name.isEmpty {
                        return name
                    }
                }
            }
            let name = url.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.capitalized
    }
}
