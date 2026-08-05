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
        // Measured 2026-08-05: 0.74 s warm with think:false.
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
        let cleaned = try JSONDecoder().decode(Generated.self, from: data)
            .response
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CleanupError.emptyResponse }
        return cleaned
    }
}
