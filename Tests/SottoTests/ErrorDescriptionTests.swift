import Foundation
import Testing
@testable import Sotto

@Suite("Transcriber error descriptions")
struct TranscriberErrorDescriptionTests {
    @Test func aMissingModelNamesItsPathAndSaysWhereToFixIt() {
        let error = TranscriberError.modelMissing("/nowhere/ggml-absent.bin")

        #expect(
            error.description
                == "no whisper model at /nowhere/ggml-absent.bin; check settings.json's whisperModelPath."
        )
    }

    @Test func aWhisperFailureNamesItsExitCodeAndStderr() {
        let error = TranscriberError.whisperFailed(exitCode: 134, stderr: "GGML_ASSERT failed")

        #expect(error.description.contains("134"))
        #expect(error.description.contains("GGML_ASSERT failed"))
    }

    @Test func everyTranscriberErrorDescribesItself() {
        let cases: [TranscriberError] = [
            .whisperBinaryMissing("/opt/homebrew/bin/whisper-cli"),
            .modelMissing("/nowhere/ggml-absent.bin"),
            .whisperFailed(exitCode: 134, stderr: "GGML_ASSERT failed"),
            .whisperFailedWithoutDetail(exitCode: 1),
            .warmUpClipAllocationFailed,
            .emptyTranscript,
        ]
        for error in cases {
            #expect(!error.description.isEmpty)
            #expect(!error.description.contains("TranscriberError("))
        }
    }
}

@Suite("Insertion error descriptions")
struct InsertionErrorDescriptionTests {
    @Test func aChangedPasteboardNamesBothCounts() {
        let error = InsertionError.pasteboardChangedDuringInsertion(expected: 4, actual: 7)

        #expect(
            error.description
                == "the pasteboard changed during insertion (expected change count 4, got 7), so nothing was restored"
        )
    }

    @Test func anUnreadableTypeNamesIt() {
        let error = InsertionError.pasteboardTypeUnreadable("com.adobe.pdf")

        #expect(error.description.contains("com.adobe.pdf"))
    }

    @Test func everyInsertionErrorDescribesItself() {
        let cases: [InsertionError] = [
            .secureInputActive,
            .pasteboardUnreadable,
            .pasteboardTypeUnreadable("com.adobe.pdf"),
            .pasteboardWriteFailed,
            .pasteboardChangedDuringInsertion(expected: 4, actual: 7),
            .eventCreationFailed,
        ]
        for error in cases {
            #expect(!error.description.isEmpty)
            #expect(!error.description.contains("InsertionError("))
        }
    }
}
