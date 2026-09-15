import AppKit
import ServiceManagement

/// Builds and owns the menu bar item: dictation on/off, launch-at-login, and the last 20
/// transcripts. Every collaborator is a plain closure, not a protocol with a real and a fake
/// implementation — `SMAppService` and the live event tap are both real system state a stub
/// protocol would only pretend to model. Toggling dictation off calls `stopDictation`, which in
/// production is `DictationController.stopListening()` — the tap teardown, not a flag flip.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let history: History
    private let hotkeyLabel: String?
    private let startDictation: () throws -> Void
    private let stopDictation: () -> Void
    private let registerLoginItem: () throws -> Void
    // `SMAppService.unregister()` is `async throws` in the real API — it waits for the running
    // process to be killed — while `register()` is synchronous. The mismatch is Apple's, not
    // invented here.
    private let unregisterLoginItem: () async throws -> Void
    private let loginItemStatus: () -> SMAppService.Status
    private let copyToPasteboard: (String) -> Void
    private let showHistory: () -> Void

    private var isDictationEnabled: Bool
    private var dictationError: String?
    private var loginItemError: String?
    private var failureReason: String?
    private var cleanupWarning: String?
    // Captured at construction time so `clearFailure()` restores the exact image the caller set,
    // rather than guessing a name back.
    private let normalImage: NSImage?

    private(set) var menu = NSMenu()

    init(
        statusItem: NSStatusItem,
        history: History,
        hotkeyLabel: String?,
        dictationEnabled: Bool,
        dictationError: String?,
        startDictation: @escaping () throws -> Void,
        stopDictation: @escaping () -> Void,
        registerLoginItem: @escaping () throws -> Void,
        unregisterLoginItem: @escaping () async throws -> Void,
        loginItemStatus: @escaping () -> SMAppService.Status,
        copyToPasteboard: @escaping (String) -> Void,
        showHistory: @escaping () -> Void = {}
    ) {
        self.statusItem = statusItem
        normalImage = statusItem.button?.image
        self.history = history
        self.hotkeyLabel = hotkeyLabel
        isDictationEnabled = dictationEnabled
        self.dictationError = dictationError
        self.startDictation = startDictation
        self.stopDictation = stopDictation
        self.registerLoginItem = registerLoginItem
        self.unregisterLoginItem = unregisterLoginItem
        self.loginItemStatus = loginItemStatus
        self.copyToPasteboard = copyToPasteboard
        self.showHistory = showHistory
        super.init()
        rebuildMenu()
    }

    @objc func toggleDictation() {
        if isDictationEnabled {
            stopDictation()
            isDictationEnabled = false
            dictationError = nil
        } else {
            do {
                try startDictation()
                isDictationEnabled = true
                dictationError = nil
            } catch {
                isDictationEnabled = false
                dictationError = "\(error)"
            }
        }
        rebuildMenu()
    }

    @objc func toggleLoginItem() {
        guard loginItemStatus() == .enabled else {
            do {
                try registerLoginItem()
                loginItemError = nil
            } catch {
                loginItemError = "\(error)"
            }
            rebuildMenu()
            return
        }
        // The only async collaborator in this class, because it is the one place the real API is
        // async: `SMAppService.unregister()` waits for the running process to be killed.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.unregisterLoginItem()
                self.loginItemError = nil
            } catch {
                self.loginItemError = "\(error)"
            }
            self.rebuildMenu()
        }
    }

    @objc func openHistory() {
        showHistory()
    }

    @objc func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let transcript = sender.representedObject as? String else { return }
        copyToPasteboard(transcript)
    }

    func reportFailure(_ reason: String) {
        failureReason = reason
        statusItem.button?.image = NSImage(systemSymbolName: "mic.badge.xmark", accessibilityDescription: nil)
        rebuildMenu()
    }

    func clearFailure() {
        failureReason = nil
        statusItem.button?.image = normalImage
        rebuildMenu()
    }

    func setCleanupWarning(_ text: String?) {
        cleanupWarning = text
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let dictationItem = NSMenuItem(
            title: isDictationEnabled ? "Turn Dictation Off" : "Turn Dictation On",
            action: #selector(toggleDictation),
            keyEquivalent: ""
        )
        dictationItem.target = self
        menu.addItem(dictationItem)

        if let failureReason {
            let failure = NSMenuItem(
                title: "Last dictation failed: \(failureReason) — Settings…",
                action: nil,
                keyEquivalent: ""
            )
            failure.isEnabled = false
            menu.addItem(failure)
        }

        if let cleanupWarning {
            let warning = NSMenuItem(
                title: "Cleanup model '\(cleanupWarning)' not installed — Settings…",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
        }

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginItemStatus() == .enabled ? .on : .off
        menu.addItem(loginItem)

        if let loginItemError {
            let failure = NSMenuItem(title: "Launch at Login failed: \(loginItemError)", action: nil, keyEquivalent: "")
            failure.isEnabled = false
            menu.addItem(failure)
        }

        menu.addItem(.separator())
        let header = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for item in recentTranscriptItems() {
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let historyItem = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "y")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        self.menu = menu
        statusItem.menu = menu
    }

    private var statusText: String {
        if let dictationError { return "Not running: \(dictationError)" }
        guard isDictationEnabled else { return "Dictation off" }
        // No hotkey means settings never loaded, so there is no key to name. Say that, rather than
        // rendering "hold " with an invented blank.
        guard let hotkeyLabel else { return "Listening" }
        return "Listening — hold \(hotkeyLabel)"
    }

    // Most recent first, so the entry you just dictated is the one at the top when a paste went to
    // the wrong window.
    private func recentTranscriptItems() -> [NSMenuItem] {
        let transcripts = history.transcripts
        guard !transcripts.isEmpty else {
            let empty = NSMenuItem(title: "No recent transcripts", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return [empty]
        }
        return transcripts.reversed().map { transcript in
            let item = NSMenuItem(title: Self.truncated(transcript), action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = transcript
            return item
        }
    }

    private static func truncated(_ transcript: String, limit: Int = 60) -> String {
        transcript.count > limit ? String(transcript.prefix(limit)) + "…" : transcript
    }
}
