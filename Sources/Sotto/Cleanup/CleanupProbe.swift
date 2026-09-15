import Foundation

enum ProbeVerdict: Equatable {
    case pass(warnings: [String])
    case fail(reason: String)
}

// A pure judge of a cleanup model's fitness: given the result of one real round-trip through
// `fixture`, decides pass/warn/fail without touching a server, so the definition of "pass" lives
// here and only here.
enum CleanupProbe {
    // Built to catch four things at once: filler to remove (um, uh), a vocabulary-shaped token that
    // must survive (pnpm), a trailing question that must come back as a question, and an answer
    // trap (a model that answers rather than cleans will say "Paris").
    static let fixture =
        "so um I think we should run pnpm install first and then uh what's the capital of France anyway"

    static func verdict(output: String?, error: CleanupError?, elapsed: TimeInterval, warm: Bool) -> ProbeVerdict {
        if let error {
            // Names it with the error's own description, so this reason is never a paraphrase.
            return .fail(reason: error.description)
        }
        guard let output else {
            preconditionFailure("verdict needs an output when no error was thrown")
        }

        // The answer trap: a model that answers the fixture's question instead of cleaning it says
        // "Paris" rather than returning the question.
        if output.lowercased().contains("paris") {
            return .fail(reason: "the model answered the question instead of cleaning it (contains 'Paris')")
        }

        // Catches a leak that somehow carried no think tag: a cleaned sentence never triples in size.
        if output.count > fixture.count * 3 {
            return .fail(
                reason: "output is \(output.count) characters, more than 3x the fixture's \(fixture.count) "
                    + "— it rambled"
            )
        }

        var warnings: [String] = []

        if !output.hasSuffix("?") {
            warnings.append("output does not end in '?'")
        }

        let words = Set(output.lowercased().split { !$0.isLetter }.map(String.init))
        if words.contains("um") || words.contains("uh") {
            warnings.append("filler word ('um'/'uh') survived")
        }

        if !output.lowercased().contains("pnpm") {
            warnings.append("'pnpm' is missing from the output")
        }

        // 5 s warm / 15 s cold: UX budgets, not hard failures — a slow model still cleaned correctly.
        let budget: TimeInterval = warm ? 5 : 15
        if elapsed > budget {
            warnings.append("elapsed \(elapsed)s exceeds the \(warm ? "warm" : "cold") budget of \(budget)s")
        }

        return .pass(warnings: warnings)
    }

    // Two failures look alike but are fixed differently — this tells them apart using elapsed time,
    // since on localhost a refused connection fails in milliseconds, so a slow `.backendUnavailable`
    // means the server accepted the request and never finished.
    static func remedy(for error: CleanupError, elapsed: TimeInterval) -> String {
        switch error {
        case let .requestFailed(status, _):
            if status == 404 {
                return "the model is not installed — install it or pick another"
            }
            return error.description
        case .backendUnavailable:
            // The request timeout is 20 s (CleanupHTTP.timeout); this close to it, it timed out.
            if elapsed >= 19 {
                return "the request timed out — pick a faster model"
            }
            return "the Ollama daemon is not running — start Ollama"
        case .missingKey, .requestFailedWithoutDetail, .nonHTTPResponse, .emptyResponse, .reasoningLeaked:
            return error.description
        }
    }
}
