enum VocabularyError: Error, Equatable {
    case tooLong(estimatedTokens: Int)
}

enum Vocabulary {
    // Whisper truncates a `--prompt` over 224 tokens silently rather than refusing it, so this must
    // reject an over-long list before whisper-cli ever sees it.
    static let tokenLimit = 224

    // No tokeniser is available on this machine (no Xcode, no bundled whisper tokeniser library).
    // ~4 characters per token is the commonly cited approximation for English/code-like text and is
    // used here as a conservative pre-flight estimate.
    private static let charactersPerToken = 4

    static func whisperPrompt(_ terms: [String]) throws -> String? {
        guard !terms.isEmpty else { return nil }
        let joined = terms.joined(separator: ", ")
        let estimatedTokens = (joined.count + charactersPerToken - 1) / charactersPerToken
        guard estimatedTokens <= tokenLimit else {
            throw VocabularyError.tooLong(estimatedTokens: estimatedTokens)
        }
        return joined
    }
}
