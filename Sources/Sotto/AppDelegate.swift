import AVFoundation
import AppKit
import ApplicationServices
import ServiceManagement

private struct LaunchFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Homebrew's whisper-cpp location. Not a settings key: the settings file names the *model*, which
    // is the thing a user changes. A missing binary throws from Transcriber naming this path.
    private static let whisperBinaryPath = "/opt/homebrew/bin/whisper-cli"

    static let diagnosticsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Sotto.log")

    static func diagnose(_ message: String) {
        NSLog("Sotto: \(message)")
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: diagnosticsPath) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: diagnosticsPath)
        }
    }

    private var statusItem: NSStatusItem?
    private var controller: DictationController?
    private var menuBar: MenuBarController?
    private let pill = PillWindow()
    private let history = History()
    private let store = HistoryStore()
    private var historyWindow: HistoryWindowController?
    private var hotkeyLabel: String?
    private var cleaner: Cleaner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPresence.install()

        // A click on a terminal pill already hides it; opening the destination is task 19.
        pill.onActivate = { _ in }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Sotto")
        statusItem = item

        // macOS only lists an app under Microphone once it has asked, so this call is what makes the
        // grant reachable at all. Sotto is LSUIElement, so it activates first — a background app with
        // no Dock presence does not reliably surface the TCC dialog.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Self.diagnose("microphone status at launch = \(micStatus.rawValue) (0=notDetermined 2=denied 3=authorized)")
        if micStatus == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Self.diagnose("microphone requestAccess returned granted=\(granted)")
            }
        }

        let onAlarm: @Sendable (HotkeyAlarm) -> Void = { alarm in
            NSLog("Sotto: hotkey alarm raised — \(alarm). Rules 1-4 of task 3 have been violated.")
        }
        let copyToPasteboard: (String) -> Void = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        do {
            let settings = try Settings.load()
            hotkeyLabel = settings.hotkey
            // The same backend the cleanup pass uses. Enhance is a second prompt over one client,
            // not a second provider to configure. Built once here, in a CleanerSlot, so the settings
            // panel can swap the model later without relaunching Sotto.
            let cleanerSlot = try DictationController.cleaner(for: settings).map {
                CleanerSlot($0, model: settings.cleanupModel)
            }
            cleaner = cleanerSlot
            // Measured 8.44 s cold against 0.91 s warm: without this the first dictation after a
            // reboot takes eight seconds. Off the main thread, or it delays launch by exactly that.
            let transcriber = Transcriber(binaryPath: Self.whisperBinaryPath, modelPath: settings.whisperModelPath)
            let warmUp: @Sendable () -> Void = {
                DispatchQueue.global(qos: .utility).async {
                    do { try transcriber.warmUp() } catch {
                        NSLog("Sotto: warm-up failed — \(error). The first dictation pays the cold cost.")
                    }
                }
            }
            warmUp()

            // Once per launch, not per dictation: the trim rewrites the whole file.
            store.trim(now: Date())

            let controller = try DictationController(
                settings: settings,
                whisperBinaryPath: Self.whisperBinaryPath,
                cleaner: cleanerSlot,
                onLevel: { [pill] level in pill.updateLevel(level) },
                history: history,
                store: store
            ) { [pill] sequence, state in
                Self.diagnose("job \(sequence) → \(state)")
                DispatchQueue.main.async {
                    guard let visible = PillState(state) else { return pill.hide() }
                    pill.show(visible)
                }
            }
            self.controller = controller

            // Written to a file, not just NSLog: the only launch whose TCC attribution is correct is
            // one via LaunchServices, and that launch has no terminal to print to.
            Self.diagnose("preflight — listenEvent=\(CGPreflightListenEventAccess()) axTrusted=\(AXIsProcessTrusted()) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")

            var launchError: String?
            do {
                try controller.startListening(onAlarm: onAlarm)
                Self.diagnose("startListening succeeded — hotkey \(settings.hotkey) is live")
            } catch {
                Self.diagnose("startListening FAILED — \(error)")
                // A launch failure is never silent: it reaches the menu and the pill.
                launchError = "\(error)"
                pill.show(.failed(stage: .launch, reason: "\(error)"))
            }

            menuBar = MenuBarController(
                statusItem: item,
                history: history,
                hotkeyLabel: settings.hotkey,
                dictationEnabled: launchError == nil,
                dictationError: launchError,
                startDictation: {
                    try controller.startListening(onAlarm: onAlarm)
                    warmUp()
                },
                stopDictation: { controller.stopListening() },
                registerLoginItem: { try SMAppService.mainApp.register() },
                unregisterLoginItem: { try await SMAppService.mainApp.unregister() },
                loginItemStatus: { SMAppService.mainApp.status },
                copyToPasteboard: copyToPasteboard,
                showHistory: { [weak self] in self?.showHistory() }
            )
        } catch {
            let message = "\(error)"
            menuBar = MenuBarController(
                statusItem: item,
                history: history,
                hotkeyLabel: nil,
                dictationEnabled: false,
                dictationError: message,
                startDictation: { throw LaunchFailure(message: message) },
                stopDictation: {},
                registerLoginItem: { try SMAppService.mainApp.register() },
                unregisterLoginItem: { try await SMAppService.mainApp.unregister() },
                loginItemStatus: { SMAppService.mainApp.status },
                copyToPasteboard: copyToPasteboard,
                showHistory: { [weak self] in self?.showHistory() }
            )
            pill.show(.failed(stage: .launch, reason: message))
        }
    }

    private func showHistory() {
        let controller = historyWindow ?? HistoryWindowController(store: store, hotkeyLabel: hotkeyLabel, cleaner: cleaner)
        historyWindow = controller
        controller.show()
    }

    /// Sotto has no Dock icon, so relaunching it from Spotlight or Finder reactivates the running
    /// process instead of starting a second one. Without this the Return key appears to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showHistory()
        return true
    }
}
