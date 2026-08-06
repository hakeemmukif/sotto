import Foundation
import Testing
@testable import Sotto

@Suite("Vocabulary — the whisper prompt loader")
struct VocabularyTests {
    // 200 four-character terms joined by ", " is 1198 characters; at the ~4-chars-per-token
    // estimate that is 300 tokens, comfortably past whisper's 224-token prompt cap.
    @Test func aThreeHundredTokenVocabularyThrowsTooLong() throws {
        let terms = Array(repeating: "abcd", count: 200)

        #expect(throws: VocabularyError.tooLong(estimatedTokens: 300)) {
            try Vocabulary.whisperPrompt(terms)
        }
    }

    @Test func anEmptyVocabularyProducesNoPrompt() throws {
        #expect(try Vocabulary.whisperPrompt([]) == nil)
    }

    @Test func aShortVocabularyJoinsIntoOnePrompt() throws {
        #expect(try Vocabulary.whisperPrompt(["pnpm", "Drizzle"]) == "pnpm, Drizzle")
    }
}

@Suite("AppProfiles — bundle id to prompt fragment")
struct AppProfilesTests {
    private let profiles = [
        "default": "Fix punctuation and capitalisation using standard sentence case.",
        "com.apple.Terminal": "Lowercase, no trailing period.",
    ]

    @Test func anUnmappedBundleIdResolvesToTheDefaultProfile() throws {
        let profile = try AppProfiles.profile(for: "com.example.unknown", in: profiles)

        #expect(profile == profiles["default"])
    }

    @Test func aMappedBundleIdResolvesToItsOwnProfile() throws {
        let profile = try AppProfiles.profile(for: "com.apple.Terminal", in: profiles)

        #expect(profile == "Lowercase, no trailing period.")
    }

    // No frontmost app is a real state (NSWorkspace.frontmostApplication is optional). Treated the
    // same as an unmapped bundle id, not as a reason to throw.
    @Test func aNilBundleIdResolvesToTheDefaultProfile() throws {
        let profile = try AppProfiles.profile(for: nil, in: profiles)

        #expect(profile == profiles["default"])
    }

    @Test func settingsLackingADefaultProfileThrows() {
        #expect(throws: AppProfileError.missingDefaultProfile) {
            try AppProfiles.profile(for: "com.apple.Terminal", in: ["com.apple.Terminal": "Lowercase."])
        }
    }
}
