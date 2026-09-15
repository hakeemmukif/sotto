import AppKit
import Carbon
import CoreGraphics
import Foundation

enum InsertionError: Error, Equatable, CustomStringConvertible {
    case secureInputActive
    case pasteboardUnreadable
    case pasteboardTypeUnreadable(String)
    case pasteboardWriteFailed
    case pasteboardChangedDuringInsertion(expected: Int, actual: Int)
    case eventCreationFailed

    var description: String {
        switch self {
        case .secureInputActive:
            "secure input is active, so the keystroke would be dropped silently"
        case .pasteboardUnreadable:
            "the pasteboard's items could not be read"
        case let .pasteboardTypeUnreadable(type):
            "the pasteboard type \(type) could not be read, so it cannot be restored"
        case .pasteboardWriteFailed:
            "writing to the pasteboard failed"
        case let .pasteboardChangedDuringInsertion(expected, actual):
            "the pasteboard changed during insertion (expected change count \(expected), got \(actual)), so nothing was restored"
        case .eventCreationFailed:
            "could not create the synthetic keyboard event"
        }
    }
}

/// The proof that secure input was checked. `insert` cannot be called without one and the only way
/// to obtain one is `permitInsertion()`, so the check cannot drift to after the user has spoken.
struct InsertionPermit: Sendable {
    fileprivate init() {}
}

/// Unchecked because `NSPasteboard` carries no `Sendable` annotation. Task 13 serialises insertion by
/// sequence number, so only one call is ever in flight.
struct TextInserter: @unchecked Sendable {
    // A paste has no completion callback: the target app reads the pasteboard on its own schedule
    // after the Cmd-V arrives, so restoring immediately makes it paste the *old* contents. 150 ms is
    // the empirical figure this class of app uses.
    static let restoreDelay: TimeInterval = 0.150

    private static let vKeyCode: CGKeyCode = 9
    // The keycode is ignored once a unicode string is attached, so any key will do as the carrier.
    private static let unicodeCarrierKeyCode: CGKeyCode = 0

    let pasteboard: NSPasteboard
    let mode: InsertionMode
    let isSecureInputEnabled: @Sendable () -> Bool

    init(
        pasteboard: NSPasteboard = .general,
        mode: InsertionMode,
        isSecureInputEnabled: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.pasteboard = pasteboard
        self.mode = mode
        self.isSecureInputEnabled = isSecureInputEnabled
    }

    /// Call this before recording starts. In a password field or a terminal with secure keyboard
    /// entry, synthetic events are dropped without a trace, and refusing here costs the user a red
    /// pill instead of twenty seconds of speech.
    func permitInsertion() throws -> InsertionPermit {
        guard !isSecureInputEnabled() else { throw InsertionError.secureInputActive }
        return InsertionPermit()
    }

    func insert(_ text: String, permit _: InsertionPermit) throws {
        // Secure input can be switched on while the user is still speaking, and the permit was taken
        // before that. Inserting anyway would drop the keystroke silently.
        guard !isSecureInputEnabled() else { throw InsertionError.secureInputActive }

        switch mode {
        case .paste:
            try paste(text)
        case .unicodeKeystrokes:
            let (down, up) = try TextInserter.unicodeEvents(for: text)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func paste(_ text: String) throws {
        let saved = try snapshot()

        let expected = pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw InsertionError.pasteboardWriteFailed
        }

        let (down, up) = try TextInserter.pasteEvents()
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        Thread.sleep(forTimeInterval: TextInserter.restoreDelay)

        // Cross-check: a different change count means something else wrote to the pasteboard inside
        // the window, and restoring would destroy content Sotto did not put there.
        let actual = pasteboard.changeCount
        guard actual == expected else {
            throw InsertionError.pasteboardChangedDuringInsertion(expected: expected, actual: actual)
        }

        try restore(saved)
    }

    private func snapshot() throws -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pasteboard.pasteboardItems else {
            throw InsertionError.pasteboardUnreadable
        }
        return try items.map { item in
            var saved: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // A type that cannot be read cannot be restored, and clearing the pasteboard would
                // destroy it. Refuse the insertion rather than lose the user's clipboard.
                guard let data = item.data(forType: type) else {
                    throw InsertionError.pasteboardTypeUnreadable(type.rawValue)
                }
                saved[type] = data
            }
            return saved
        }
    }

    private func restore(_ saved: [[NSPasteboard.PasteboardType: Data]]) throws {
        // Built before the clear, so a failure here leaves the pasteboard as it is.
        var items: [NSPasteboardItem] = []
        for types in saved {
            let item = NSPasteboardItem()
            for (type, data) in types {
                guard item.setData(data, forType: type) else {
                    throw InsertionError.pasteboardWriteFailed
                }
            }
            items.append(item)
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else {
            throw InsertionError.pasteboardWriteFailed
        }
    }

    static func pasteEvents() throws -> (down: CGEvent, up: CGEvent) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else {
            throw InsertionError.eventCreationFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        return (down, up)
    }

    static func unicodeEvents(for text: String) throws -> (down: CGEvent, up: CGEvent) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: unicodeCarrierKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: unicodeCarrierKeyCode, keyDown: false)
        else {
            throw InsertionError.eventCreationFailed
        }
        let utf16 = Array(text.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        return (down, up)
    }
}
