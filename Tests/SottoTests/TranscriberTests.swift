import Foundation
import Testing
@testable import Sotto

private let whisperBinary = "/opt/homebrew/bin/whisper-cli"
private let mediumModel = "~/Library/Application Support/Sotto/models/ggml-medium.en.bin"

private func benchWav(from filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent() // Tests/SottoTests/
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures/bench.wav")
}

@Suite("Transcription — drives the real whisper-cli", .serialized)
struct TranscriberTests {
    @Test func benchClipTranscribesItsKeyPhrases() throws {
        let transcriber = Transcriber(binaryPath: whisperBinary, modelPath: mediumModel)
        let text = try transcriber.transcribe(benchWav(), vocabularyPrompt: nil)

        #expect(text.contains("authentication fix"))
        #expect(text.contains("migration"))
    }

    // Ordering is asserted inside the test rather than assumed: the first call pays whatever cold
    // cost is outstanding, so the second is the one the budget describes. Limit measured 2026-11-05
    // with ggml-medium.en: 1.02-1.10 s alone (5 runs), 0.96-1.90 s inside the full suite (5 runs), and
    // a 2.08 s spike seen in a full-suite run while other suites competed for CPU; 2.5 s is that max
    // rounded up to the next 0.5 s.
    @Test func aWarmRunCompletesUnderTwoAndAHalfSeconds() throws {
        let transcriber = Transcriber(binaryPath: whisperBinary, modelPath: mediumModel)
        _ = try transcriber.transcribe(benchWav(), vocabularyPrompt: nil)

        let start = Date()
        _ = try transcriber.transcribe(benchWav(), vocabularyPrompt: nil)

        #expect(Date().timeIntervalSince(start) < 2.5)
    }

    @Test func warmUpRunsWithoutATranscript() throws {
        let transcriber = Transcriber(binaryPath: whisperBinary, modelPath: mediumModel)
        try transcriber.warmUp()
    }

    @Test func aTildeInTheModelPathIsExpanded() {
        let transcriber = Transcriber(binaryPath: whisperBinary, modelPath: mediumModel)

        #expect(!transcriber.modelPath.contains("~"))
        #expect(FileManager.default.isReadableFile(atPath: transcriber.modelPath))
    }

    @Test func aMissingModelThrowsNamingThePath() {
        let transcriber = Transcriber(binaryPath: whisperBinary, modelPath: "/nowhere/ggml-absent.bin")

        #expect(throws: TranscriberError.modelMissing("/nowhere/ggml-absent.bin")) {
            try transcriber.transcribe(benchWav(), vocabularyPrompt: nil)
        }
    }

    @Test func aMissingBinaryThrowsNamingIt() {
        let transcriber = Transcriber(binaryPath: "/nowhere/whisper-cli", modelPath: mediumModel)

        #expect(throws: TranscriberError.whisperBinaryMissing("/nowhere/whisper-cli")) {
            try transcriber.transcribe(benchWav(), vocabularyPrompt: nil)
        }
    }
}
