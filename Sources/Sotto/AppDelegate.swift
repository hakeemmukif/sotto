import AVFoundation
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Homebrew's whisper-cpp location. Not a settings key: the settings file names the *model*, which
    // is the thing a user changes. A missing binary throws from Transcriber naming this path.
    private static let whisperBinaryPath = "/opt/homebrew/bin/whisper-cli"

    private var statusItem: NSStatusItem?
    private var controller: DictationController?
    private let pill = PillWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Sotto")
        statusItem = item

        // macOS only lists an app under Microphone once it has asked, so this call is what makes the
        // grant reachable at all.
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        do {
            let settings = try Settings.load()
            let controller = try DictationController(
                settings: settings,
                whisperBinaryPath: Self.whisperBinaryPath
            ) { [pill] _, state in
                DispatchQueue.main.async {
                    guard let visible = PillState(state) else { return pill.hide() }
                    pill.show(visible)
                }
            }
            try controller.startListening { alarm in
                NSLog("Sotto: hotkey alarm raised — \(alarm). Rules 1-4 of task 3 have been violated.")
            }
            self.controller = controller
            setMenu(status: "Listening — hold \(settings.hotkey)")
        } catch {
            // A launch failure is never silent: it reaches the menu and the pill.
            setMenu(status: "Not running: \(error)")
            pill.show(.failed("\(error)"))
        }
    }

    private func setMenu(status: String) {
        let menu = NSMenu()
        let line = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        line.isEnabled = false
        menu.addItem(line)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
}
