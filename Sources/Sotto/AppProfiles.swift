enum AppProfileError: Error, Equatable {
    case missingDefaultProfile
}

enum AppProfiles {
    // `default` must exist in every settings file, unconditionally — not only when a lookup would
    // fall back to it — so a settings file that could silently stop covering an app is caught
    // immediately rather than the first time that app loses its specific profile.
    static func profile(for bundleID: String?, in profiles: [String: String]) throws -> String {
        guard let defaultProfile = profiles["default"] else {
            throw AppProfileError.missingDefaultProfile
        }
        guard let bundleID, let specific = profiles[bundleID] else {
            return defaultProfile
        }
        return specific
    }
}
