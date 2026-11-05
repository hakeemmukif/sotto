import Foundation
import Testing
@testable import Sotto

private func repoRoot(from filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent() // Tests/SottoTests/
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // repo root
}

private func writeFixture(_ json: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sotto-settings-\(UUID().uuidString).json")
    try json.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func validFixtureParses() throws {
    let url = repoRoot().appendingPathComponent("settings.example.json")
    let settings = try Settings.load(from: url)

    #expect(settings.hotkey == "fn")
    #expect(settings.whisperBackend == .local)
    #expect(settings.cleanupBackend == .none)
    #expect(settings.cleanupModel == "qwen3:8b")
    #expect(settings.vocabulary.isEmpty)
    #expect(settings.appProfiles["default"] != nil)
    #expect(settings.insertionMode == .paste)
}

@Test func unknownInsertionModeThrows() throws {
    let fixture = """
    {
      "hotkey": "fn",
      "whisperModelPath": "/tmp/model.bin",
      "whisperBackend": "local",
      "cleanupBackend": "ollama",
      "cleanupModel": "qwen3:8b",
      "vocabulary": [],
      "appProfiles": {},
      "insertionMode": "telepathy"
    }
    """
    let url = try writeFixture(fixture)
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        _ = try Settings.load(from: url)
        Issue.record("expected SettingsError.unknownInsertionMode to be thrown")
    } catch let error as SettingsError {
        #expect(error == .unknownInsertionMode("telepathy"))
    } catch {
        Issue.record("expected SettingsError, got \(error)")
    }
}

@Test func missingWhisperModelPathThrowsMissingKey() throws {
    let fixture = """
    {
      "hotkey": "fn",
      "whisperBackend": "local",
      "cleanupBackend": "ollama",
      "cleanupModel": "qwen3:8b",
      "vocabulary": [],
      "appProfiles": {},
      "insertionMode": "paste"
    }
    """
    let url = try writeFixture(fixture)
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        _ = try Settings.load(from: url)
        Issue.record("expected SettingsError.missingKey to be thrown")
    } catch let error as SettingsError {
        #expect(error == .missingKey("whisperModelPath"))
    } catch {
        Issue.record("expected SettingsError, got \(error)")
    }
}

@Test func unknownCleanupBackendThrowsUnknownBackend() throws {
    let fixture = """
    {
      "hotkey": "fn",
      "whisperModelPath": "/tmp/model.bin",
      "whisperBackend": "local",
      "cleanupBackend": "banana",
      "cleanupModel": "qwen3:8b",
      "vocabulary": [],
      "appProfiles": {},
      "insertionMode": "paste"
    }
    """
    let url = try writeFixture(fixture)
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        _ = try Settings.load(from: url)
        Issue.record("expected SettingsError.unknownBackend to be thrown")
    } catch let error as SettingsError {
        #expect(error == .unknownBackend("banana"))
    } catch {
        Issue.record("expected SettingsError, got \(error)")
    }
}
