import Foundation

struct OpenAICompatibleBackend: Cleaner {
    static let groqEndpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    static let openAIEndpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    let endpoint: URL
    let model: String
    let apiKey: String

    static func groq(model: String, envFiles: [URL] = EnvFile.defaultSearchPaths) throws -> OpenAICompatibleBackend {
        OpenAICompatibleBackend(
            endpoint: groqEndpoint,
            model: model,
            apiKey: try EnvFile.require("GROQ_API_KEY", in: envFiles)
        )
    }

    static func openAI(model: String, envFiles: [URL] = EnvFile.defaultSearchPaths) throws -> OpenAICompatibleBackend {
        OpenAICompatibleBackend(
            endpoint: openAIEndpoint,
            model: model,
            apiKey: try EnvFile.require("OPENAI_API_KEY", in: envFiles)
        )
    }

    private struct Completion: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    private struct Completed: Decodable {
        let choices: [Choice]

        struct Choice: Decodable {
            let message: Message

            struct Message: Decodable {
                let content: String
            }
        }
    }

    func clean(_ transcript: String, system: String) async throws -> String {
        let body = try JSONEncoder().encode(
            Completion(
                model: model,
                messages: [.init(role: "system", content: system), .init(role: "user", content: transcript)],
                temperature: 0.1
            )
        )
        let data = try await CleanupHTTP.post(
            json: body,
            to: endpoint,
            headers: ["Authorization": "Bearer \(apiKey)"]
        )
        guard let choice = try JSONDecoder().decode(Completed.self, from: data).choices.first else {
            throw CleanupError.emptyResponse
        }
        let cleaned = choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CleanupError.emptyResponse }
        return cleaned
    }
}

enum EnvFile {
    static let defaultSearchPaths: [URL] = [
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/sotto/.env"),
    ]

    static func require(_ name: String, in files: [URL]) throws -> String {
        for url in files where FileManager.default.isReadableFile(atPath: url.path) {
            let contents = try String(contentsOf: url, encoding: .utf8)
            for line in contents.split(separator: "\n") {
                let entry = line.trimmingCharacters(in: .whitespaces)
                guard entry.hasPrefix("\(name)=") else { continue }
                let value = entry
                    .dropFirst(name.count + 1)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                // An empty value is a missing key, not a key worth sending to the server.
                if !value.isEmpty { return value }
            }
        }
        throw CleanupError.missingKey(name)
    }
}
