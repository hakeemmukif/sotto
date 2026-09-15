import Foundation
import Testing
@testable import Sotto

// Captured 2026-09-15 against a locally running Ollama 0.34.0.
private let tagsFixture = Data("""
{"models":[{"name":"qwen2.5:3b-instruct","model":"qwen2.5:3b-instruct","modified_at":"2026-09-14T21:49:35.165184664+08:00","size":1929912432,"digest":"357c53fb659c5076de1d65ccb0b397446227b71a42be9d1603d46168015c9e4b","details":{"parent_model":"","format":"gguf","family":"qwen2","families":["qwen2"],"parameter_size":"3.1B","quantization_level":"Q4_K_M","context_length":32768,"embedding_length":2048},"capabilities":["completion","tools"]},{"name":"qwen3:4b","model":"qwen3:4b","modified_at":"2026-09-14T21:46:15.534159611+08:00","size":2497293931,"digest":"359d7dd4bcdab3d86b87d73ac27966f4dbb9f5efdfcc75d34a8764a09474fae7","details":{"parent_model":"","format":"gguf","family":"qwen3","families":["qwen3"],"parameter_size":"4.0B","quantization_level":"Q4_K_M","context_length":262144,"embedding_length":2560},"capabilities":["completion","tools","thinking"]},{"name":"qwen38-obl:latest","model":"qwen38-obl:latest","modified_at":"2026-09-11T23:24:10.850196302+08:00","size":16810715956,"digest":"0e8b8f674ce064cad4c1fbbf1e93e2c4113726041b1b14885bf4a53d7de244cf","details":{"parent_model":"","format":"gguf","family":"qwen35","families":["qwen35"],"parameter_size":"27.3B","quantization_level":"Q4_K_M","context_length":262144,"embedding_length":5120},"capabilities":["completion","tools","thinking"]},{"name":"qwen38-fast:latest","model":"qwen38-fast:latest","modified_at":"2026-09-11T19:50:45.750691567+08:00","size":17741872212,"digest":"14b568cea1b4746adb2812c80cdf5ad594be597fe16c48b29aacbf8f2f0b91b9","details":{"parent_model":"qwen3.8:27b","format":"gguf","family":"qwen35","families":["qwen35"],"parameter_size":"27.3B","quantization_level":"Q4_K_M","context_length":262144,"embedding_length":5120},"capabilities":["completion","tools","thinking","vision"]},{"name":"qwen3.8:27b","model":"qwen3.8:27b","modified_at":"2026-09-11T19:12:29.778561838+08:00","size":17741872154,"digest":"22130167c4c20e20c7b71454612966ca8e8171e9b3cc8ab6ce8aa6cbfec79643","details":{"parent_model":"qwen3.8:27b-q4_K_M","format":"gguf","family":"qwen35","families":["qwen35"],"parameter_size":"27.3B","quantization_level":"Q4_K_M","context_length":262144,"embedding_length":5120},"capabilities":["completion","tools","thinking","vision"]},{"name":"nomic-embed-text:latest","model":"nomic-embed-text:latest","modified_at":"2026-08-29T17:27:47.202677852+08:00","size":274302450,"digest":"0a109f422b47e3a30ba2b10eca18548e944e8a23073ee3f3e947efcf3c45e59f","details":{"parent_model":"","format":"gguf","family":"nomic-bert","families":["nomic-bert"],"parameter_size":"137M","quantization_level":"F16","context_length":2048,"embedding_length":768},"capabilities":["embedding"]}]}
""".utf8)

// Captured 2026-09-15 — one model was loaded (qwen2.5:3b-instruct) so this is the real shape rather
// than a hand-written one.
private let psFixture = Data("""
{"models":[{"name":"qwen2.5:3b-instruct","model":"qwen2.5:3b-instruct","size":2438903889,"digest":"357c53fb659c5076de1d65ccb0b397446227b71a42be9d1603d46168015c9e4b","details":{"parent_model":"","format":"gguf","family":"qwen2","families":["qwen2"],"parameter_size":"3.1B","quantization_level":"Q4_K_M"},"expires_at":"2026-09-15T23:49:07.20026+08:00","size_vram":2438903889,"context_length":16384}]}
""".utf8)

private let versionFixture = Data("""
{"version":"0.34.0"}
""".utf8)

@Suite("OllamaProbe — decoding /api/tags")
struct OllamaProbeTagsDecodingTests {
    @Test func theRealTagsFixtureDecodesWithSpecificFieldsIntact() throws {
        let models = try JSONDecoder().decode(OllamaProbe.TagsResponse.self, from: tagsFixture).models
        let qwen = try #require(models.first { $0.name == "qwen2.5:3b-instruct" })

        #expect(qwen.size == 1_929_912_432)
        #expect(qwen.parameterSize == "3.1B")
        #expect(qwen.quantizationLevel == "Q4_K_M")
        #expect(qwen.family == "qwen2")
    }

    // This distinction is the whole point of the probe: the panel warns when the selected cleanup
    // model can reason (and so can leak a <think> block, per OllamaBackend.parse) rather than only
    // clean text.
    @Test func qwenInstructHasCompletionButNotThinkingWhileAQwen3TagDoes() throws {
        let models = try JSONDecoder().decode(OllamaProbe.TagsResponse.self, from: tagsFixture).models
        let instruct = try #require(models.first { $0.name == "qwen2.5:3b-instruct" })
        let reasoning = try #require(models.first { $0.name == "qwen3:4b" })

        #expect(instruct.canComplete)
        #expect(!instruct.isReasoningModel)
        #expect(reasoning.isReasoningModel)
    }

    @Test func anEmbeddingOnlyModelHasNoCompletionCapability() throws {
        let models = try JSONDecoder().decode(OllamaProbe.TagsResponse.self, from: tagsFixture).models
        let embedder = try #require(models.first { $0.name == "nomic-embed-text:latest" })

        #expect(embedder.capabilities.contains("embedding"))
        #expect(!embedder.canComplete)
    }

    // Pins the no-fallback rule: a model missing `capabilities` must throw rather than decode with
    // an empty or assumed capability list.
    @Test func aTagsEntryWithoutCapabilitiesThrowsRatherThanDefaulting() {
        let withoutCapabilities = Data("""
        {"models":[{"name":"qwen2.5:3b-instruct","size":1929912432,"details":{"parameter_size":"3.1B","quantization_level":"Q4_K_M","family":"qwen2"}}]}
        """.utf8)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(OllamaProbe.TagsResponse.self, from: withoutCapabilities)
        }
    }
}

@Suite("OllamaProbe — decoding /api/ps and /api/version")
struct OllamaProbePsAndVersionDecodingTests {
    @Test func theRealPsFixtureDecodesItsRequiredFields() throws {
        let models = try JSONDecoder().decode(OllamaProbe.PsResponse.self, from: psFixture).models
        let loaded = try #require(models.first)

        #expect(loaded.name == "qwen2.5:3b-instruct")
        #expect(loaded.expiresAt == "2026-09-15T23:49:07.20026+08:00")
        #expect(loaded.sizeVRAM == 2_438_903_889)
    }

    @Test func theRealVersionFixtureDecodes() throws {
        let version = try JSONDecoder().decode(OllamaProbe.VersionResponse.self, from: versionFixture).version

        #expect(version == "0.34.0")
    }
}
