import Foundation

/// The only writer of settings.json. The user hand-edits this file, so writing means
/// read-modify-write on the raw JSON object rather than encoding a `Settings` snapshot: encoding
/// from the launch-time snapshot would silently clobber any key they changed since launch.
enum SettingsFile {
    enum FileError: Error, Equatable {
        case notAJSONObject
    }

    static func readCleanupModel(at url: URL) throws -> String {
        try Settings.load(from: url).cleanupModel
    }

    /// Order matters: the new bytes are validated by decoding `Settings` from them before
    /// anything touches disk, so a bad write throws and the file on disk is untouched.
    static func write(cleanupModel: String, at url: URL) throws {
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FileError.notAJSONObject
        }
        object["cleanupModel"] = cleanupModel

        // JSONSerialization.jsonObject already parses into an unordered Swift Dictionary, so the
        // original key order is gone before we ever get here — .sortedKeys trades it for an order
        // that is at least stable across writes instead of reshuffling arbitrarily each time.
        let newData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        _ = try JSONDecoder().decode(Settings.self, from: newData)

        try newData.write(to: url, options: .atomic)
    }
}
