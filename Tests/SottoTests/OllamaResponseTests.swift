import Foundation
import Testing
@testable import Sotto

// Verified 2026-09-15 against Ollama 0.34.0: qwen3:4b ignores `think: false` and emits its reasoning
// as ordinary response text — the `thinking` field is null and the literal `</think>` tag arrives
// inside `response`. A 9-word transcript produced 20,945 characters in 63.9 s. Nothing in the
// decoding path looked for the tag, so `clean()` returned the monologue and it would have been
// pasted into whatever the user was typing in.
@Suite("Ollama — reading a generate response")
struct OllamaResponseTests {
    private let model = "qwen3:4b"

    @Test func aClosingThinkTagIsALeakRatherThanTextToPasteOn() throws {
        let leaked = "Okay, the user wants me to clean this up. Let me think.\n</think>\n\nShip it."

        #expect(throws: CleanupError.reasoningLeaked(model: model, characters: leaked.count)) {
            try OllamaBackend.parse(response: leaked, model: model)
        }
    }

    // The opening tag alone is the same failure: the parser must not depend on which half of the
    // pair survives whatever partial stripping the server did.
    @Test func anOpeningThinkTagIsAlsoALeak() throws {
        let leaked = "<think> Let me work through this one step at a time."

        #expect(throws: CleanupError.reasoningLeaked(model: model, characters: leaked.count)) {
            try OllamaBackend.parse(response: leaked, model: model)
        }
    }

    // The tail after `</think>` is usually the correct answer, which is exactly why stripping is
    // tempting and wrong: it would accept a model that costs 60–90 s per dictation and hide that.
    @Test func theTailAfterTheTagIsNeverSalvaged() throws {
        let leaked = "reasoning…\n</think>\n\nCan you send me the Drizzle migration file?"

        #expect(throws: CleanupError.self) {
            try OllamaBackend.parse(response: leaked, model: model)
        }
    }

    @Test func aCleanResponseIsReturnedTrimmed() throws {
        let parsed = try OllamaBackend.parse(response: "  Ship the history window.\n\n", model: model)

        #expect(parsed == "Ship the history window.")
    }

    @Test func aResponseOfOnlyWhitespaceIsEmptyRatherThanValid() throws {
        #expect(throws: CleanupError.emptyResponse) {
            try OllamaBackend.parse(response: "   \n  ", model: model)
        }
    }

    // A transcript may legitimately mention the word; only the tag is a leak.
    @Test func theWordThinkInDictatedTextIsNotALeak() throws {
        let parsed = try OllamaBackend.parse(response: "I think we should ship it.", model: model)

        #expect(parsed == "I think we should ship it.")
    }
}

@Suite("Cleanup requests — how long we wait")
struct CleanupRequestTests {
    private let endpoint = URL(string: "http://localhost:11434/api/generate")!

    // URLSession's 60 s default is measured between bytes, and `stream: false` means Ollama sends
    // nothing until it has finished. A model that reasons for 64 s therefore looked like a stalled
    // connection rather than a slow model. 20 s bounds it: past that the transcript is pasted raw
    // rather than held hostage to a model that is never coming back in time.
    @Test func aCleanupRequestGivesUpAfterTwentySeconds() {
        let request = CleanupHTTP.makeRequest(json: Data(), endpoint: endpoint, headers: [:])

        #expect(request.timeoutInterval == 20)
    }

    @Test func aCleanupRequestCarriesItsBodyMethodAndHeaders() {
        let body = Data("{\"model\":\"qwen2.5:3b-instruct\"}".utf8)
        let request = CleanupHTTP.makeRequest(
            json: body,
            endpoint: endpoint,
            headers: ["Authorization": "Bearer sk-test"]
        )

        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == body)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.url == endpoint)
    }
}

@Suite("Cleanup errors — what the user is told")
struct CleanupErrorDescriptionTests {
    @Test func aLeakNamesTheModelAndTheSize() {
        let error = CleanupError.reasoningLeaked(model: "qwen3:4b", characters: 20945)

        #expect(
            error.description
                == "model 'qwen3:4b' leaked reasoning into its output (20,945 characters). Pick a different model."
        )
    }

    // The 404 body Ollama returns already names the missing model, so the description carries it
    // through rather than inventing a second sentence about it.
    @Test func anHTTPFailureCarriesTheServersOwnExplanation() {
        let error = CleanupError.requestFailed(
            status: 404,
            body: "{\"error\":\"model 'qwen3:8b' not found\"}"
        )

        #expect(
            error.description
                == "cleanup request failed (HTTP 404): {\"error\":\"model 'qwen3:8b' not found\"}"
        )
    }

    @Test func anUnreachableBackendSaysSoWithoutAStatusCode() {
        #expect(CleanupError.backendUnavailable.description == "the cleanup backend is unreachable")
    }

    @Test func everyCleanupErrorDescribesItself() {
        let errors: [CleanupError] = [
            .missingKey("GROQ_API_KEY"),
            .backendUnavailable,
            .requestFailed(status: 500, body: "boom"),
            .requestFailedWithoutDetail(status: 502),
            .nonHTTPResponse,
            .emptyResponse,
            .reasoningLeaked(model: "qwen3:4b", characters: 12),
        ]

        for error in errors {
            #expect(!error.description.isEmpty, "\(error) has no description")
            #expect(!error.description.contains("CleanupError("), "\(error) fell back to the synthesised description")
        }
    }
}
