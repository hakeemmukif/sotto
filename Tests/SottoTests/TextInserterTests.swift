import AppKit
import Carbon
import CoreGraphics
import Foundation
import Testing
@testable import Sotto

// Every test gets its own uniquely-named pasteboard. `.general` is the user's real clipboard and the
// suite must never write to it.
private func privatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("com.hakeem.sotto.tests-\(UUID().uuidString)"))
}

private func tiffBytes() throws -> Data {
    let rep = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 4,
        pixelsHigh: 4,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ))
    return try #require(rep.tiffRepresentation)
}

private func seed(_ pasteboard: NSPasteboard, string: String, tiff: Data) {
    let text = NSPasteboardItem()
    #expect(text.setString(string, forType: .string))
    let image = NSPasteboardItem()
    #expect(image.setData(tiff, forType: .tiff))
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([text, image]))
}

private final class SecureInputFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    var current: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

@Suite("Cursor insertion", .serialized)
struct TextInserterTests {
    // The headline clause: saving only `.string` would restore the text and destroy the image.
    @Test func aStringAndATIFFAreBothRestoredAfterInsertion() throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let tiff = try tiffBytes()
        seed(pasteboard, string: "the user's own clipboard", tiff: tiff)

        let inserter = TextInserter(pasteboard: pasteboard, mode: .paste, isSecureInputEnabled: { false })
        try inserter.insert("dictated text", permit: inserter.permitInsertion())

        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.count == 2)
        #expect(pasteboard.string(forType: .string) == "the user's own clipboard")
        #expect(pasteboard.data(forType: .tiff) == tiff)
        #expect(items.map(\.types) == [[.string], [.tiff]])
    }

    // A restore that skipped the empty case would leave Sotto's own dictated text on the clipboard.
    @Test func anEmptyPasteboardIsRestoredEmptyRatherThanKeepingTheDictatedText() throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        let inserter = TextInserter(pasteboard: pasteboard, mode: .paste, isSecureInputEnabled: { false })
        try inserter.insert("dictated text", permit: inserter.permitInsertion())

        #expect(try #require(pasteboard.pasteboardItems).isEmpty)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    // Requirement 4: the refusal happens up front, before the user speaks, and nothing is written.
    @Test func secureInputRefusesAPermitAndWritesNothing() throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let tiff = try tiffBytes()
        seed(pasteboard, string: "untouched", tiff: tiff)
        let before = pasteboard.changeCount

        let inserter = TextInserter(pasteboard: pasteboard, mode: .paste, isSecureInputEnabled: { true })

        #expect(throws: InsertionError.secureInputActive) {
            try inserter.permitInsertion()
        }
        #expect(pasteboard.changeCount == before)
        #expect(pasteboard.string(forType: .string) == "untouched")
        #expect(pasteboard.data(forType: .tiff) == tiff)
    }

    // The injection seam exists for this suite. If it ever defaulted to `false`, requirement 4 would
    // be silently disabled in production and every test here would still pass.
    @Test func theDefaultInserterAsksTheRealSecureInputAPI() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }

        let inserter = TextInserter(pasteboard: pasteboard, mode: .paste)

        #expect(inserter.isSecureInputEnabled() == IsSecureEventInputEnabled())
    }

    // Secure input can be switched on while the user is still speaking. Pasting into it would drop
    // the keystroke silently, so the transcript must not be reported as inserted.
    @Test func secureInputTurningOnAfterThePermitStillRefusesAndLeavesTheClipboard() throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let tiff = try tiffBytes()
        seed(pasteboard, string: "untouched", tiff: tiff)

        let flag = SecureInputFlag(false)
        let inserter = TextInserter(pasteboard: pasteboard, mode: .paste, isSecureInputEnabled: { flag.current })
        let permit = try inserter.permitInsertion()
        flag.set(true)
        let before = pasteboard.changeCount

        #expect(throws: InsertionError.secureInputActive) {
            try inserter.insert("dictated text", permit: permit)
        }
        #expect(pasteboard.changeCount == before)
        #expect(pasteboard.string(forType: .string) == "untouched")
    }

    // The changeCount cross-check. Another writer inside the restore window means restoring would
    // destroy content Sotto did not put there.
    @Test func aPasteboardWrittenByAnotherAppDuringTheWindowIsNotClobbered() throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        seed(pasteboard, string: "the user's own clipboard", tiff: try tiffBytes())

        let inserter = TextInserter(pasteboard: pasteboard, mode: .paste, isSecureInputEnabled: { false })
        let permit = try inserter.permitInsertion()

        nonisolated(unsafe) let interloper = pasteboard
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            interloper.clearContents()
            interloper.setString("a clipboard manager got here first", forType: .string)
        }

        do {
            try inserter.insert("dictated text", permit: permit)
            Issue.record("expected a thrown error, the restore overwrote another app's write")
        } catch let error as InsertionError {
            guard case let .pasteboardChangedDuringInsertion(expected, actual) = error else {
                Issue.record("expected .pasteboardChangedDuringInsertion, got \(error)")
                return
            }
            #expect(actual > expected)
        }
        #expect(pasteboard.string(forType: .string) == "a clipboard manager got here first")
    }

    // Decision 8: keystroke synthesis is the opt-in path and it has no business touching the
    // clipboard at all.
    @Test func unicodeModeLeavesThePasteboardUntouched() throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let tiff = try tiffBytes()
        seed(pasteboard, string: "untouched", tiff: tiff)
        let before = pasteboard.changeCount

        let inserter = TextInserter(
            pasteboard: pasteboard,
            mode: .unicodeKeystrokes,
            isSecureInputEnabled: { false }
        )
        try inserter.insert("dictated text", permit: inserter.permitInsertion())

        #expect(pasteboard.changeCount == before)
        #expect(pasteboard.string(forType: .string) == "untouched")
        #expect(pasteboard.data(forType: .tiff) == tiff)
    }

    // Construction only. Without Accessibility no assertion here can prove the keystroke was
    // delivered to anything.
    @Test func thePasteEventsAreCommandVDownAndUp() throws {
        let (down, up) = try TextInserter.pasteEvents()

        #expect(down.getIntegerValueField(.keyboardEventKeycode) == 9)
        #expect(up.getIntegerValueField(.keyboardEventKeycode) == 9)
        #expect(down.flags.contains(.maskCommand))
        #expect(up.flags.contains(.maskCommand))
        #expect(down.type == .keyDown)
        #expect(up.type == .keyUp)
    }

    // Construction only, and the reason the unicode string is not chunked: a single event carries a
    // full dictation-length string without truncating it.
    @Test func theUnicodeEventsCarryTheWholeStringUntruncated() throws {
        let text = "Ship the authentication fix — check the Drizzle migration ran on staging first."
        let (down, up) = try TextInserter.unicodeEvents(for: text)

        #expect(readUnicodeString(down) == text)
        #expect(readUnicodeString(up) == text)
        #expect(text.utf16.count > 20)
    }
}

private func readUnicodeString(_ event: CGEvent) -> String {
    var buffer = [UniChar](repeating: 0, count: 512)
    var length = 0
    event.keyboardGetUnicodeString(maxStringLength: 512, actualStringLength: &length, unicodeString: &buffer)
    return String(utf16CodeUnits: buffer, count: length)
}
