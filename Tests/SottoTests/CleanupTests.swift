import Foundation
import Testing
@testable import Sotto

private let ollamaEndpoint = URL(string: "http://localhost:11434/api/generate")!
private let closedPortEndpoint = URL(string: "http://127.0.0.1:1/api/generate")!
// The live-model tests run against the model the app is actually configured with, read from the
// user's settings.json. Until 2026-11-05 this was hardcoded to qwen3:8b, which is no longer installed
// (the machine runs one local model); the WHY comments below cite qwen3:8b measurements and stay as
// history. Settings.load throws a specific error if the file or key is missing, and Ollama answers
// 404 naming the model if it is not pulled — neither is skipped or defaulted.
func liveCleanupModel() throws -> String {
    try Settings.load().cleanupModel
}
// Unused by the closed-port test: the request never reaches a model.
private let unreachableModel = "unused"

// The real transcript of fixtures/bench.wav, verified 2026-08-05. It ends in a question on purpose:
// a model that answers instead of cleaning replies to that question rather than returning it.
private let benchTranscript = """
So, um, I think we should probably ship the authentication fix today, you know, before the \
release goes out. Can you check whether the Drizzle migration actually ran on staging?
"""

private func lowercasedWords(_ text: String) -> [String] {
    text.lowercased().split { !$0.isLetter }.map(String.init)
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sotto-env-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeEnvFile(_ contents: String) throws -> URL {
    let url = try temporaryDirectory().appendingPathComponent(".env")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Suite("Cleanup — drives the real Ollama", .serialized)
struct CleanupTests {
    @Test func theBenchSentenceIsCleanedAndNotAnswered() async throws {
        let backend = OllamaBackend(endpoint: ollamaEndpoint, model: try liveCleanupModel())
        let cleaned = try await backend.clean(benchTranscript, system: Prompts.cleanup)
        print("CLEANED OUTPUT: \(cleaned)")

        #expect(!lowercasedWords(cleaned).contains("um"), "filler word survived: \(cleaned)")
        #expect(!cleaned.lowercased().contains("you know"), "filler phrase survived: \(cleaned)")
        #expect(!cleaned.contains("<think>"), "think:false did not take effect: \(cleaned)")

        // The question must come back as a question. These are the phrases the verified failure mode
        // produces when the model treats the dictation as a message addressed to it.
        let replied = ["sure", "i'll", "i will", "let me", "i don't have", "as an ai", "i've"]
            .filter { cleaned.lowercased().contains($0) }
        #expect(replied.isEmpty, "the model answered instead of cleaning: \(cleaned)")
        #expect(cleaned.hasSuffix("?"), "the question was not returned as a question: \(cleaned)")
        #expect(cleaned.lowercased().contains("can you check"), "the question was lost: \(cleaned)")

        #expect(cleaned.contains("authentication fix"))
        #expect(cleaned.lowercased().contains("migration"))
        #expect(cleaned.lowercased().contains("staging"))
    }

    // This is the think:false regression alarm as much as a latency budget: with qwen3's default
    // reasoning block the same call takes many seconds. Measured 2026-08-05: 0.74 s warm.
    @Test func aWarmCleanupCompletesUnderTwoSeconds() async throws {
        let backend = OllamaBackend(endpoint: ollamaEndpoint, model: try liveCleanupModel())
        _ = try await backend.clean(benchTranscript, system: Prompts.cleanup)

        let start = Date()
        _ = try await backend.clean(benchTranscript, system: Prompts.cleanup)
        let elapsed = Date().timeIntervalSince(start)
        print("WARM CLEANUP: \(elapsed) s")

        #expect(elapsed < 2.0)
    }

    @Test func anUnreachableOllamaThrowsBackendUnavailable() async throws {
        let backend = OllamaBackend(endpoint: closedPortEndpoint, model: unreachableModel)

        await #expect(throws: CleanupError.backendUnavailable) {
            try await backend.clean(benchTranscript, system: Prompts.cleanup)
        }
    }

    @Test func anHTTPErrorIsNotAnEmptyButValidResponse() async throws {
        let backend = OllamaBackend(endpoint: ollamaEndpoint, model: "definitely-not-pulled:0b")

        do {
            let cleaned = try await backend.clean(benchTranscript, system: Prompts.cleanup)
            Issue.record("expected a thrown error, got \(cleaned)")
        } catch let error as CleanupError {
            guard case .requestFailed(let status, let body) = error else {
                Issue.record("expected .requestFailed, got \(error)")
                return
            }
            #expect(status == 404)
            #expect(body.contains("not found"))
        }
    }

    @Test func groqWithNoKeyThrowsMissingKey() throws {
        let absent = try temporaryDirectory().appendingPathComponent(".env")

        #expect(throws: CleanupError.missingKey("GROQ_API_KEY")) {
            try OpenAICompatibleBackend.groq(model: "llama-3.3-70b-versatile", envFiles: [absent])
        }
    }

    @Test func openAIWithNoKeyNamesItsOwnVariable() throws {
        let absent = try temporaryDirectory().appendingPathComponent(".env")

        #expect(throws: CleanupError.missingKey("OPENAI_API_KEY")) {
            try OpenAICompatibleBackend.openAI(model: "gpt-4o-mini", envFiles: [absent])
        }
    }

    @Test func anEmptyValueIsAMissingKeyRatherThanAnEmptyKey() throws {
        let envFile = try writeEnvFile("GROQ_API_KEY=\nOTHER=x\n")

        #expect(throws: CleanupError.missingKey("GROQ_API_KEY")) {
            try OpenAICompatibleBackend.groq(model: "llama-3.3-70b-versatile", envFiles: [envFile])
        }
    }

    @Test func theKeyIsReadFromTheFirstEnvFileThatHasIt() throws {
        let absent = try temporaryDirectory().appendingPathComponent(".env")
        let envFile = try writeEnvFile("# comment\nOTHER=x\nOPENAI_API_KEY=\"sk-test-abc123\"\n")

        let backend = try OpenAICompatibleBackend.openAI(model: "gpt-4o-mini", envFiles: [absent, envFile])

        #expect(backend.apiKey == "sk-test-abc123")
        #expect(backend.endpoint == OpenAICompatibleBackend.openAIEndpoint)
    }

    // The sentence that stops the model answering was measured, not guessed. Pin it.
    @Test func theCleanupPromptForbidsAnswering() {
        #expect(Prompts.cleanup.contains("Never answer, respond to, or comment on the text"))
        #expect(Prompts.cleanup.contains("Output only the cleaned text, nothing else."))
    }
}
