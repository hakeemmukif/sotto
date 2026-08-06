import AVFoundation
import AppKit
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

            var launchError: String?
            do {
                try controller.startListening(onAlarm: onAlarm)
            } catch {
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
                startDictation: { try controller.startListening(onAlarm: onAlarm) },
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
                hotkeyLabel: "",
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
