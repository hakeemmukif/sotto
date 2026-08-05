import Foundation

enum SettingsError: Error, Equatable {
    case missingKey(String)
    case unknownBackend(String)
    case unknownInsertionMode(String)
}

enum InsertionMode: String, Equatable {
    case paste
    case unicodeKeystrokes
}

enum WhisperBackend: String, Equatable {
    case local
    case groq
    case openai
}

enum CleanupBackend: String, Equatable {
    case ollama
    case groq
    case openai
    case none
}

struct Settings: Equatable {
    let hotkey: String
    let whisperModelPath: String
    let whisperBackend: WhisperBackend
    let cleanupBackend: CleanupBackend
    let cleanupModel: String
    let vocabulary: [String]
    let appProfiles: [String: String]
    let insertionMode: InsertionMode
}

extension Settings: Decodable {
    private enum CodingKeys: String, CodingKey {
        case hotkey, whisperModelPath, whisperBackend, cleanupBackend, cleanupModel, vocabulary, appProfiles, insertionMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func requireString(_ key: CodingKeys) throws -> String {
            guard container.contains(key) else {
                throw SettingsError.missingKey(key.rawValue)
            }
            return try container.decode(String.self, forKey: key)
        }

        hotkey = try requireString(.hotkey)
        whisperModelPath = try requireString(.whisperModelPath)

        let whisperBackendRaw = try requireString(.whisperBackend)
        guard let whisperBackend = WhisperBackend(rawValue: whisperBackendRaw) else {
            throw SettingsError.unknownBackend(whisperBackendRaw)
        }
        self.whisperBackend = whisperBackend

        let cleanupBackendRaw = try requireString(.cleanupBackend)
        guard let cleanupBackend = CleanupBackend(rawValue: cleanupBackendRaw) else {
            throw SettingsError.unknownBackend(cleanupBackendRaw)
        }
        self.cleanupBackend = cleanupBackend

        cleanupModel = try requireString(.cleanupModel)

        guard container.contains(.vocabulary) else {
            throw SettingsError.missingKey(CodingKeys.vocabulary.rawValue)
        }
        vocabulary = try container.decode([String].self, forKey: .vocabulary)

        guard container.contains(.appProfiles) else {
            throw SettingsError.missingKey(CodingKeys.appProfiles.rawValue)
        }
        appProfiles = try container.decode([String: String].self, forKey: .appProfiles)

        let insertionModeRaw = try requireString(.insertionMode)
        guard let insertionMode = InsertionMode(rawValue: insertionModeRaw) else {
            throw SettingsError.unknownInsertionMode(insertionModeRaw)
        }
        self.insertionMode = insertionMode
    }
}

extension Settings {
    static let defaultURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Sotto/settings.json")

    static func load(from url: URL = Settings.defaultURL) throws -> Settings {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Settings.self, from: data)
    }
}
