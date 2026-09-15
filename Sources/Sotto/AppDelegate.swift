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

    // Only "Microphone" is ever produced today (DictationController.beginRecording), but the pane
    // lookup stays a map rather than a single case so a name with no pane logs instead of guessing.
    private static let systemSettingsPanes: [String: URL] = [
        "Microphone": URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!,
    ]

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
    private var register: CleanupFailureRegister?
    private var modelSettingsModel: ModelSettingsModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPresence.install()

        pill.onActivate = { [weak self] route in
            guard let self else { return }
            // A second job can still be recording, transcribing, or cleaning while an older pill's
            // route fires. Opening a window would activate Sotto and steal focus from whatever app
            // that job's eventual paste is meant to land in, so a live job means the click only
            // dismissed the pill — the never-activate invariant holds either way.
            guard self.controller?.hasJobsInFlight != true else { return }
            switch route {
            case .settings: self.showSettings()
            case .history: self.showHistory()
            case let .systemSettings(what):
                guard let url = Self.systemSettingsPanes[what] else {
                    Self.diagnose("no System Settings pane mapped for permission \"\(what)\"")
                    return
                }
                NSWorkspace.shared.open(url)
            }
        }

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
            let register = CleanupFailureRegister()
            self.register = register

            // Same vocabulary prompt DictationController builds below, computed here too so the
            // settings panel's Test button sends exactly what a real dictation would send, not a
            // bare Prompts.cleanup — a model that only leaks reasoning under the real prompt would
            // otherwise pass its own health check.
            let vocabularyPrompt = try Vocabulary.whisperPrompt(settings.vocabulary)
            let ollamaProbe = OllamaProbe()
            // Ties to `cleanerSlot`'s own nil-ness: with no running cleaner there is nothing this
            // panel could test or apply against, so there is no settings model either.
            modelSettingsModel = cleanerSlot.map { slot in
                ModelSettingsModel(
                    backend: settings.cleanupBackend,
                    register: register,
                    now: Date.init,
                    fetchVersion: { try await ollamaProbe.version() },
                    fetchInstalledModels: { try await ollamaProbe.installedModels() },
                    fetchLoadedModels: { try await ollamaProbe.loadedModels() },
                    readFileModel: { try SettingsFile.readCleanupModel(at: Settings.defaultURL) },
                    writeFileModel: { try SettingsFile.write(cleanupModel: $0, at: Settings.defaultURL) },
                    makeCleaner: { model in
                        ProfiledCleaner(
                            underlying: OllamaBackend(model: model),
                            appProfiles: settings.appProfiles,
                            vocabulary: vocabularyPrompt
                        )
                    },
                    applyToSlot: { cleaner, model in slot.replace(cleaner, model: model) },
                    slotModel: { slot.model },
                    copyToPasteboard: copyToPasteboard,
                    openFile: { NSWorkspace.shared.open($0) }
                )
            }

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
            ) { [pill, register, weak self] sequence, state in
                Self.diagnose("job \(sequence) → \(state)")
                register.record(sequence: sequence, state: state, at: Date())
                DispatchQueue.main.async {
                    if let visible = PillState(state) {
                        pill.show(visible)
                    } else {
                        pill.hide()
                    }
                    switch state {
                    case .recording, .transcribing, .cleaning, .inserting,
                         .cancelled, .aborted, .secureInputActive, .backendUnavailable:
                        break
                    case let .permissionMissing(what):
                        self?.menuBar?.reportFailure("\(what) permission missing")
                    case let .failed(_, reason):
                        self?.menuBar?.reportFailure(reason)
                    case .done:
                        self?.menuBar?.clearFailure()
                    }
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
                showHistory: { [weak self] in self?.showHistory() },
                showSettings: { [weak self] in self?.showSettings() }
            )

            if settings.cleanupBackend == .ollama {
                checkCleanupModelInstalled(model: settings.cleanupModel)
            }
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
                showHistory: { [weak self] in self?.showHistory() },
                showSettings: { [weak self] in self?.showSettings() }
            )
            pill.show(.failed(stage: .launch, reason: message))
        }
    }

    private func showHistory() {
        let controller = historyWindow ?? HistoryWindowController(
            store: store, hotkeyLabel: hotkeyLabel, cleaner: cleaner, model: modelSettingsModel
        )
        historyWindow = controller
        controller.show()
    }

    // Tab index 2 is Settings — see the tab bar's titles in HistoryWindow.swift. ⌘, lands here
    // instead of wherever the window last happened to be showing.
    private func showSettings() {
        let controller = historyWindow ?? HistoryWindowController(
            store: store, hotkeyLabel: hotkeyLabel, cleaner: cleaner, model: modelSettingsModel
        )
        historyWindow = controller
        controller.show(tab: 2)
    }

    // Ollama can answer "is this model installed" in milliseconds, so there is no excuse for
    // cleanup to fail silently at first dictation the way it did for five days when settings.json
    // named a model that was never pulled. Off the main thread like the transcriber warm-up above,
    // for the same reason: a synchronous network call here would delay launch.
    private func checkCleanupModelInstalled(model: String) {
        Task.detached(priority: .utility) {
            do {
                let installed = try await OllamaProbe().installedModels()
                if !installed.contains(where: { $0.name == model }) {
                    await Self.diagnose("cleanup model '\(model)' not installed")
                    await MainActor.run { [weak self] in self?.menuBar?.setCleanupWarning(model) }
                }
            } catch {
                // The daemon being unreachable is not the same fact as the model being missing —
                // Ollama.app may still be starting at login, and a menu warning on every cold boot
                // would be noise the amber/raw-paste path at runtime already covers.
                await Self.diagnose("cleanup model presence check failed — \(error)")
            }
        }
    }

    /// Sotto has no Dock icon, so relaunching it from Spotlight or Finder reactivates the running
    /// process instead of starting a second one. Without this the Return key appears to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showHistory()
        return true
    }
}
