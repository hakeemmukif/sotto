import Foundation

/// Read-only queries against the local Ollama daemon, so the settings panel can show which models
/// are installed, which one is loaded, and whether the daemon is up at all. Never mutates anything.
struct OllamaProbe {
    static let defaultBaseURL = URL(string: "http://localhost:11434")!

    let baseURL: URL

    init(baseURL: URL = OllamaProbe.defaultBaseURL) {
        self.baseURL = baseURL
    }

    struct VersionResponse: Decodable {
        let version: String
    }

    struct TagsResponse: Decodable {
        let models: [InstalledModel]
    }

    struct PsResponse: Decodable {
        let models: [LoadedModel]
    }

    func version() async throws -> String {
        let data = try await CleanupHTTP.get(baseURL.appendingPathComponent("api/version"))
        return try JSONDecoder().decode(VersionResponse.self, from: data).version
    }

    func installedModels() async throws -> [InstalledModel] {
        let data = try await CleanupHTTP.get(baseURL.appendingPathComponent("api/tags"))
        return try JSONDecoder().decode(TagsResponse.self, from: data).models
    }

    func loadedModels() async throws -> [LoadedModel] {
        let data = try await CleanupHTTP.get(baseURL.appendingPathComponent("api/ps"))
        return try JSONDecoder().decode(PsResponse.self, from: data).models
    }
}

struct InstalledModel: Decodable, Equatable, Sendable {
    let name: String
    let size: Int64
    let parameterSize: String
    let quantizationLevel: String
    let family: String
    let capabilities: [String]

    // The two questions the settings panel actually needs answered: would this model reason before
    // answering (OllamaBackend already treats a leaked <think> block as an error, so warning about it
    // up front is the point), and can it produce a completion at all rather than only embeddings.
    var isReasoningModel: Bool { capabilities.contains("thinking") }
    var canComplete: Bool { capabilities.contains("completion") }

    private enum CodingKeys: String, CodingKey {
        case name, size, capabilities, details
    }

    private enum DetailsCodingKeys: String, CodingKey {
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
        case family
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        size = try container.decode(Int64.self, forKey: .size)
        capabilities = try container.decode([String].self, forKey: .capabilities)

        let details = try container.nestedContainer(keyedBy: DetailsCodingKeys.self, forKey: .details)
        parameterSize = try details.decode(String.self, forKey: .parameterSize)
        quantizationLevel = try details.decode(String.self, forKey: .quantizationLevel)
        family = try details.decode(String.self, forKey: .family)
    }
}

struct LoadedModel: Decodable, Equatable, Sendable {
    let name: String
    let expiresAt: String
    let sizeVRAM: Int64

    private enum CodingKeys: String, CodingKey {
        case name
        case expiresAt = "expires_at"
        case sizeVRAM = "size_vram"
    }
}
