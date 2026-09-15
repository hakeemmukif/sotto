import SwiftUI

/// A prompt improver, not a chat: the user's draft is replaced in place by a cleaner rewrite. No
/// history, no turns — one text box that gets better when you press the button.
@MainActor
final class PromptPlaygroundModel: ObservableObject {
    private let cleaner: Cleaner?
    private var previousText: String?

    @Published var text: String = ""
    @Published private(set) var isEnhancing = false
    @Published private(set) var status: String?
    @Published private(set) var isFailure = false

    init(cleaner: Cleaner?) {
        self.cleaner = cleaner
    }

    var canEnhance: Bool {
        !isEnhancing && cleaner != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canRevert: Bool {
        previousText != nil
    }

    func enhance() {
        // Checked directly rather than trusting `canEnhance` alone: the button is disabled on
        // these conditions, but a nil backend must still report why if this is ever reached.
        guard let cleaner else {
            status = "No cleanup backend configured."
            isFailure = true
            return
        }
        guard !isEnhancing else { return }
        let draft = text
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isEnhancing = true
        status = nil
        Task {
            do {
                let result = try await cleaner.clean(draft, system: Prompts.enhance)
                previousText = draft
                text = result.trimmingCharacters(in: .whitespacesAndNewlines)
                status = "Enhanced."
                isFailure = false
            } catch {
                // No fallback: leave the user's own text exactly as typed, never the failed call's
                // partial or stale output standing in for an enhancement that didn't happen.
                text = draft
                status = Self.message(for: error)
                isFailure = true
            }
            isEnhancing = false
        }
    }

    func revert() {
        guard let previousText else { return }
        text = previousText
        self.previousText = nil
        status = nil
    }

    private static func message(for error: Error) -> String {
        if let error = error as? CleanupError, error == .backendUnavailable {
            return "Cleanup backend is unreachable."
        }
        return String(describing: error)
    }
}

struct PromptPlaygroundView: View {
    @ObservedObject var model: PromptPlaygroundModel

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $model.text)
                .scrollContentBackground(.hidden)
                .font(Chicago.body(13.5))
                .padding(7)
                .background(Color.white)
                .chicagoSunken()

            HStack(spacing: 6) {
                Button(model.isEnhancing ? "Enhancing…" : "Enhance") { model.enhance() }
                    .buttonStyle(ChicagoButtonStyle())
                    .disabled(!model.canEnhance)

                Button("Revert") { model.revert() }
                    .buttonStyle(ChicagoButtonStyle())
                    .disabled(!model.canRevert)

                Spacer()

                if let status = model.status {
                    Text(status)
                        .font(Chicago.ui(10))
                        .foregroundStyle(model.isFailure ? Chicago.warning : Chicago.muted)
                }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 6)
    }
}
