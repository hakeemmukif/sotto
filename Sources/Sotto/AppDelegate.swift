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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Sotto")
        statusItem = item

        // macOS only lists an app under Microphone once it has asked, so this call is what makes the
        // grant reachable at all.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

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

            let controller = try DictationController(
                settings: settings,
                whisperBinaryPath: Self.whisperBinaryPath,
                history: history
            ) { [pill] _, state in
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
                pill.show(.failed("\(error)"))
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
                copyToPasteboard: copyToPasteboard
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
                copyToPasteboard: copyToPasteboard
            )
            pill.show(.failed(message))
        }
    }
}
