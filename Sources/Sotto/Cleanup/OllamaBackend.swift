import Foundation

struct OllamaBackend: Cleaner {
    static let defaultEndpoint = URL(string: "http://localhost:11434/api/generate")!

    let endpoint: URL
    let model: String

    init(endpoint: URL = OllamaBackend.defaultEndpoint, model: String) {
        self.endpoint = endpoint
        self.model = model
    }

    private struct Generate: Encodable {
        let model: String
        let system: String
        let prompt: String
        let stream = false
        // qwen3 is a reasoning model and its default <think> block costs seconds for nothing here.
        // Measured 2026-08-05 against qwen3:8b: 0.74 s warm with think:false.
        //
        // Not every model honours it. Measured 2026-09-15 against qwen3:4b on Ollama 0.34.0: the
        // `thinking` field came back null and the reasoning arrived inside `response` anyway —
        // 20,945 characters in 63.9 s for a nine-word transcript. Sending this is necessary but not
        // sufficient, which is why `parse` checks the output rather than trusting the parameter.
        let think = false
        let options: Options

        struct Options: Encodable {
            let temperature: Double
        }
    }

    private struct Generated: Decodable {
        let response: String
    }

    func clean(_ transcript: String, system: String) async throws -> String {
        let body = try JSONEncoder().encode(
            Generate(model: model, system: system, prompt: transcript, options: .init(temperature: 0.1))
        )
        let data = try await CleanupHTTP.post(json: body, to: endpoint, headers: [:])
        let response = try JSONDecoder().decode(Generated.self, from: data).response
        return try Self.parse(response: response, model: model)
    }

    /// `think: false` asks for no reasoning at all, so a think tag in `response` means the model
    /// ignored the parameter — measured 2026-09-15 on Ollama 0.34.0, where qwen3:4b returned a null
    /// `thinking` field and put a 20,945-character monologue in `response` after 63.9 s. Splitting on
    /// the tag would paste the plausible tail and hide the minute it cost, which is the silent
    /// fallback this codebase forbids, so a leak is an error rather than a formatting quirk.
    static func parse(response: String, model: String) throws -> String {
        guard !response.contains("<think>"), !response.contains("</think>") else {
            throw CleanupError.reasoningLeaked(model: model, characters: response.count)
        }
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CleanupError.emptyResponse }
        return cleaned
    }
}
