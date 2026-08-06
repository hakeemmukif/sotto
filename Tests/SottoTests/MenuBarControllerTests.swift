import AppKit
import Foundation
import ServiceManagement
import Testing
@testable import Sotto

private final class Calls {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var tapInvalidated = false
    var startThrows: Error?

    func start() throws {
        startCount += 1
        if let startThrows { throw startThrows }
    }

    func stop() {
        stopCount += 1
        tapInvalidated = true
    }
}

@MainActor
private final class LoginItemStub {
    private(set) var status: SMAppService.Status
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    var registerThrows: Error?

    init(status: SMAppService.Status = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        if let registerThrows { throw registerThrows }
        status = .enabled
    }

    func unregister() async throws {
        unregisterCalls += 1
        status = .notRegistered
    }
}

private struct StubError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private final class PasteboardSpy {
    private(set) var copied: [String] = []
    func record(_ text: String) { copied.append(text) }
}

@MainActor
private func makeController(
    history: History = History(),
    hotkeyLabel: String = "fn",
    dictationEnabled: Bool = true,
    dictationError: String? = nil,
    calls: Calls = Calls(),
    loginItemStub: LoginItemStub = LoginItemStub(),
    pasteboard: PasteboardSpy = PasteboardSpy()
) -> MenuBarController {
    MenuBarController(
        statusItem: NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength),
        history: history,
        hotkeyLabel: hotkeyLabel,
        dictationEnabled: dictationEnabled,
        dictationError: dictationError,
        startDictation: { try calls.start() },
        stopDictation: { calls.stop() },
        registerLoginItem: { try loginItemStub.register() },
        unregisterLoginItem: { try await loginItemStub.unregister() },
        loginItemStatus: { loginItemStub.status },
        copyToPasteboard: { pasteboard.record($0) }
    )
}

private func titles(_ menu: NSMenu) -> [String] {
    menu.items.map(\.title)
}

// `SMAppService.unregister()` is async in the real API, so `toggleLoginItem()` fires an unstructured
// Task rather than blocking the menu action. Tests observe its result the same way
// DictationControllerTests observes job completion: poll with a timeout, not a fixed sleep.
@MainActor
private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite("Menu bar — dictation status", .serialized)
@MainActor
struct MenuBarStatusTests {
    @Test func aRunningControllerShowsListeningWithTheHotkey() {
        let controller = makeController(hotkeyLabel: "ctrl+space", dictationEnabled: true)
        #expect(titles(controller.menu).contains("Listening — hold ctrl+space"))
    }

    // Existing AppDelegate behaviour, now MenuBarController's job: a launch failure is never silent.
    @Test func aLaunchFailureStaysVisibleInTheMenu() {
        let controller = makeController(dictationEnabled: false, dictationError: "settings.json is missing")
        #expect(titles(controller.menu).contains("Not running: settings.json is missing"))
    }
}

@Suite("Menu bar — toggling dictation", .serialized)
@MainActor
struct MenuBarDictationToggleTests {
    // The security-relevant half of task 9: disabling must tear the tap down, not merely stop
    // reacting to events. `stopDictation` is exactly the closure that invalidates the real tap in
    // production (DictationController.stopListening -> HotkeyMonitor.stop -> CFMachPortInvalidate).
    @Test func togglingOffInvalidatesTheTap() {
        let calls = Calls()
        let controller = makeController(dictationEnabled: true, calls: calls)

        controller.toggleDictation()

        #expect(calls.tapInvalidated)
        #expect(calls.stopCount == 1)
        #expect(calls.startCount == 0)
        #expect(titles(controller.menu).contains("Dictation off"))
    }

    @Test func togglingOnStartsListeningAndReflectsItInTheMenu() {
        let calls = Calls()
        let controller = makeController(dictationEnabled: false, dictationError: "boom", calls: calls)

        controller.toggleDictation()

        #expect(calls.startCount == 1)
        #expect(titles(controller.menu).contains("Listening — hold fn"))
        #expect(!titles(controller.menu).contains { $0.hasPrefix("Not running") })
    }

    // No fallback: a failed re-enable must surface the real error, not silently stay quiet, and it
    // must never claim to be listening when it isn't.
    @Test func aFailedReEnableSurfacesTheErrorRatherThanFakingSuccess() {
        let calls = Calls()
        calls.startThrows = StubError(message: "still no Input Monitoring")
        let controller = makeController(dictationEnabled: false, calls: calls)

        controller.toggleDictation()

        #expect(titles(controller.menu).contains("Not running: still no Input Monitoring"))
        #expect(!titles(controller.menu).contains { $0.hasPrefix("Listening") })
    }
}

@Suite("Menu bar — launch at login", .serialized)
@MainActor
struct MenuBarLoginItemTests {
    @Test func togglingOnRegistersAndReflectsSMAppServiceStatusEnabled() throws {
        let stub = LoginItemStub(status: .notRegistered)
        let controller = makeController(loginItemStub: stub)

        controller.toggleLoginItem()

        #expect(stub.status == .enabled)
        #expect(stub.registerCalls == 1)
        let loginItem = try #require(controller.menu.items.first { $0.title == "Launch at Login" })
        #expect(loginItem.state == .on)
    }

    // `SMAppService.mainApp.register()` is expected to fail on this machine (unnotarized, not in
    // /Applications). A failure must be visible and the checkbox must not be faked into `.on`.
    @Test func aFailedRegisterIsVisibleAndTheCheckboxStaysOff() throws {
        let stub = LoginItemStub(status: .notRegistered)
        stub.registerThrows = StubError(message: "operation not permitted")
        let controller = makeController(loginItemStub: stub)

        controller.toggleLoginItem()

        #expect(stub.status == .notRegistered)
        let loginItem = try #require(controller.menu.items.first { $0.title == "Launch at Login" })
        #expect(loginItem.state == .off)
        #expect(titles(controller.menu).contains("Launch at Login failed: operation not permitted"))
    }

    // The checkbox must reflect the live status closure, not an assumption the controller made —
    // simulates the real system reporting `.requiresApproval` even though nothing threw.
    @Test func theCheckboxReflectsTheStatusClosureNotAnAssumedSuccess() throws {
        let stub = LoginItemStub(status: .requiresApproval)
        let controller = makeController(loginItemStub: stub)

        let loginItem = try #require(controller.menu.items.first { $0.title == "Launch at Login" })
        #expect(loginItem.state == .off)
    }

    @Test func togglingOffUnregisters() async throws {
        let stub = LoginItemStub(status: .enabled)
        let controller = makeController(loginItemStub: stub)

        controller.toggleLoginItem()

        #expect(await waitUntil { stub.unregisterCalls == 1 })
        #expect(stub.status == .notRegistered)
        let loginItem = try #require(controller.menu.items.first { $0.title == "Launch at Login" })
        #expect(loginItem.state == .off)
    }
}

@Suite("Menu bar — recent transcripts", .serialized)
@MainActor
struct MenuBarHistoryTests {
    @Test func emptyHistoryShowsAPlaceholder() {
        let controller = makeController(history: History())
        #expect(titles(controller.menu).contains("No recent transcripts"))
    }

    @Test func recentTranscriptsAppearMostRecentFirst() {
        let history = History()
        history.insert("first")
        history.insert("second")
        let controller = makeController(history: history)

        let all = titles(controller.menu)
        let firstIndex = all.firstIndex(of: "first")
        let secondIndex = all.firstIndex(of: "second")
        #expect(secondIndex != nil && firstIndex != nil)
        #expect(secondIndex! < firstIndex!)
    }

    @Test func selectingAHistoryEntryCopiesItToThePasteboard() throws {
        let history = History()
        history.insert("insert this")
        let pasteboard = PasteboardSpy()
        let controller = makeController(history: history, pasteboard: pasteboard)

        let item = try #require(controller.menu.items.first { $0.title == "insert this" })
        controller.copyHistoryEntry(item)

        #expect(pasteboard.copied == ["insert this"])
    }
}

@Suite("Menu bar — always has Quit", .serialized)
@MainActor
struct MenuBarQuitTests {
    @Test func theMenuAlwaysEndsInQuit() {
        let controller = makeController()
        #expect(controller.menu.items.last?.title == "Quit")
    }
}
