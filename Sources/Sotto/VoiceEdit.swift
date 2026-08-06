import ApplicationServices
import Foundation

enum VoiceEditError: Error, Equatable, CustomStringConvertible {
    case accessibilityDenied
    case selectionUnavailable
    case selectionEmpty
    case instructionEmpty

    var description: String {
        switch self {
        case .accessibilityDenied:
            "Sotto could not read the selection. Grant Accessibility in System Settings › Privacy & Security › Accessibility."
        case .selectionUnavailable:
            "This app does not hand its selected text to Sotto, so there is nothing to rewrite."
        case .selectionEmpty:
            "Nothing is selected. Select the text you want rewritten, then hold the edit hotkey."
        case .instructionEmpty:
            "Sotto heard no instruction. Say what to do with the selection, such as \"make this shorter\"."
        }
    }
}

struct VoiceEdit: Sendable {
    /// Proof that a non-empty selection was read before recording started. `replace` cannot be called
    /// without one and the only way to obtain one is `captureSelection()`, so the refusal cannot drift
    /// to after the user has already spoken.
    struct Selection: Sendable {
        let text: String
        fileprivate init(text: String) {
            self.text = text
        }
    }

    struct RewriteRequest: Equatable, Sendable {
        let system: String
        let payload: String
    }

    let cleaner: Cleaner
    let insert: @Sendable (String, InsertionPermit) throws -> Void
    /// `nil` is an app that does not expose `kAXSelectedTextAttribute`. A throw is a more specific
    /// refusal than that — the permission is missing, and naming it is not the app's fault.
    let readSelectedText: @Sendable () throws -> String?

    init(
        cleaner: Cleaner,
        insert: @escaping @Sendable (String, InsertionPermit) throws -> Void,
        readSelectedText: @escaping @Sendable () throws -> String? = { try VoiceEdit.focusedSelectedText() }
    ) {
        self.cleaner = cleaner
        self.insert = insert
        self.readSelectedText = readSelectedText
    }

    /// Call this before recording starts, for the same reason `permitInsertion()` is called before
    /// recording: an app that will not hand over its selection costs the user a red pill now instead
    /// of twenty seconds of speech that could never have been applied to anything.
    func captureSelection() throws -> Selection {
        guard let text = try readSelectedText() else { throw VoiceEditError.selectionUnavailable }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceEditError.selectionEmpty
        }
        return Selection(text: text)
    }

    /// The paste lands on top of the still-live selection, which is what makes this a replacement
    /// rather than an insertion.
    func replace(
        _ selection: Selection,
        instruction: String,
        permit: InsertionPermit
    ) async throws -> String {
        let request = try VoiceEdit.request(instruction: instruction, selection: selection)
        let rewritten = try await cleaner.clean(request.payload, system: request.system)
        try insert(rewritten, permit)
        return rewritten
    }

    static func request(instruction: String, selection: Selection) throws -> RewriteRequest {
        let spoken = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { throw VoiceEditError.instructionEmpty }
        return RewriteRequest(system: Prompts.rewrite(instruction: spoken), payload: selection.text)
    }

    static func focusedSelectedText() throws -> String? {
        // Measured 2026-08-05: without the grant every AX read returns kAXErrorAPIDisabled (-25204),
        // which is indistinguishable from an app that has no selection to give. Checking the trust
        // first keeps Sotto from blaming the app for something the user can fix.
        guard AXIsProcessTrusted() else { throw VoiceEditError.accessibilityDenied }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String else { return nil }
        return text
    }
}
