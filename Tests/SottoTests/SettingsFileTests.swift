import Foundation
import Testing
@testable import Sotto

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sotto-settingsfile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// A full, valid settings.json plus one key Settings does not know about, so the "unknown key
// survives" test has something real to lose if the read-modify-write ever went through Settings.
private let validFixture = """
{
  "hotkey": "ctrl+opt+cmd",
  "whisperModelPath": "~/Library/Application Support/Sotto/models/ggml-medium.en.bin",
  "whisperBackend": "local",
  "cleanupBackend": "ollama",
  "cleanupModel": "qwen2.5:3b-instruct",
  "vocabulary": ["pnpm", "Drizzle"],
  "appProfiles": { "default": "Fix punctuation and capitalisation using standard sentence case." },
  "insertionMode": "paste",
  "experimentalThing": 42
}
"""

private func writeSettingsFixture(_ json: String) throws -> URL {
    let url = try temporaryDirectory().appendingPathComponent("settings.json")
    try json.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Suite("SettingsFile — the only writer of settings.json")
struct SettingsFileTests {
    @Test func writingANewCleanupModelRoundTrips() throws {
        let url = try writeSettingsFixture(validFixture)

        try SettingsFile.write(cleanupModel: "llama3.1:8b", at: url)

        #expect(try Settings.load(from: url).cleanupModel == "llama3.1:8b")
    }

    @Test func everyOtherKeySurvivesTheWrite() throws {
        let url = try writeSettingsFixture(validFixture)
        let before = try Settings.load(from: url)

        try SettingsFile.write(cleanupModel: "llama3.1:8b", at: url)

        let after = try Settings.load(from: url)
        #expect(after.hotkey == before.hotkey)
        #expect(after.whisperModelPath == before.whisperModelPath)
        #expect(after.whisperBackend == before.whisperBackend)
        #expect(after.cleanupBackend == before.cleanupBackend)
        #expect(after.vocabulary == before.vocabulary)
        #expect(after.appProfiles == before.appProfiles)
        #expect(after.insertionMode == before.insertionMode)
    }

    @Test func anUnknownExtraKeySurvivesTheWrite() throws {
        let url = try writeSettingsFixture(validFixture)

        try SettingsFile.write(cleanupModel: "llama3.1:8b", at: url)

        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["experimentalThing"] as? Int == 42)
    }

    @Test func malformedJSONThrowsAndLeavesTheFileUnchanged() throws {
        let url = try writeSettingsFixture("{ not json at all")
        let original = try Data(contentsOf: url)

        #expect(throws: (any Error).self) {
            try SettingsFile.write(cleanupModel: "llama3.1:8b", at: url)
        }

        #expect(try Data(contentsOf: url) == original)
    }

    // The write touches only the cleanupModel key, so the only way the post-write file can fail
    // Settings decoding is if some other key was already broken. The whole point of the
    // decode-then-write ordering is to catch exactly that and refuse to write.
    @Test func aFileThatWouldFailSettingsDecodingIsNeverWritten() throws {
        let brokenFixture = """
        {
          "hotkey": "ctrl+opt+cmd",
          "whisperModelPath": "~/Library/Application Support/Sotto/models/ggml-medium.en.bin",
          "whisperBackend": "carrier-pigeon",
          "cleanupBackend": "ollama",
          "cleanupModel": "qwen2.5:3b-instruct",
          "vocabulary": ["pnpm", "Drizzle"],
          "appProfiles": { "default": "Fix punctuation and capitalisation using standard sentence case." },
          "insertionMode": "paste"
        }
        """
        let url = try writeSettingsFixture(brokenFixture)
        let original = try Data(contentsOf: url)

        #expect(throws: (any Error).self) {
            try SettingsFile.write(cleanupModel: "llama3.1:8b", at: url)
        }

        #expect(try Data(contentsOf: url) == original)
    }

    @Test func readCleanupModelReturnsTheCurrentValue() throws {
        let url = try writeSettingsFixture(validFixture)

        #expect(try SettingsFile.readCleanupModel(at: url) == "qwen2.5:3b-instruct")
    }

    @Test func readCleanupModelThrowsOnAMalformedFile() throws {
        let url = try writeSettingsFixture("{ not json at all")

        #expect(throws: (any Error).self) {
            try SettingsFile.readCleanupModel(at: url)
        }
    }
}
