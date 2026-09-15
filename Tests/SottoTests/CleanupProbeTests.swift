import Foundation
import Testing
@testable import Sotto

// Real recorded output from qwen2.5:3b-instruct on CleanupProbe.fixture, measured 2026-09-15, 1.39 s.
private let recordedGoodOutput =
    "I was thinking we should run pnpm install first and then what's the capital of France anyway?"

@Suite("CleanupProbe — verdict on a real cleanup round-trip")
struct CleanupProbeTests {
    @Test func aCleanFastWarmRoundTripPassesWithNoWarnings() {
        let verdict = CleanupProbe.verdict(output: recordedGoodOutput, error: nil, elapsed: 1.39, warm: true)

        #expect(verdict == .pass(warnings: []))
    }

    @Test func anOutputContainingParisFailsBecauseTheModelAnswered() {
        let verdict = CleanupProbe.verdict(
            output: "The capital of France is Paris.", error: nil, elapsed: 1.0, warm: true
        )

        guard case let .fail(reason) = verdict else {
            Issue.record("expected .fail, got \(verdict)")
            return
        }
        #expect(reason.lowercased().contains("answered"))
    }

    @Test func anOutputOverThreeTimesTheFixtureLengthFailsAsRambling() {
        let output = String(repeating: "blah ", count: 100)
        let verdict = CleanupProbe.verdict(output: output, error: nil, elapsed: 1.0, warm: true)

        guard case let .fail(reason) = verdict else {
            Issue.record("expected .fail, got \(verdict)")
            return
        }
        #expect(reason.lowercased().contains("ramble"))
    }

    @Test func anOutputWithNoTrailingQuestionMarkPassesButWarns() {
        let output = "I was thinking we should run pnpm install first and then what's the capital of France anyway"
        let verdict = CleanupProbe.verdict(output: output, error: nil, elapsed: 1.0, warm: true)

        guard case let .pass(warnings) = verdict else {
            Issue.record("expected .pass, got \(verdict)")
            return
        }
        #expect(warnings.contains { $0.contains("?") })
    }

    @Test func anOutputWhereUmSurvivesPassesButWarns() {
        let output = "um I was thinking we should run pnpm install first and then what's the capital of France anyway?"
        let verdict = CleanupProbe.verdict(output: output, error: nil, elapsed: 1.0, warm: true)

        guard case let .pass(warnings) = verdict else {
            Issue.record("expected .pass, got \(verdict)")
            return
        }
        #expect(warnings.contains { $0.contains("um") })
    }

    @Test func anOutputMissingPnpmPassesButWarns() {
        let output = "I was thinking we should run the install first and then what's the capital of France anyway?"
        let verdict = CleanupProbe.verdict(output: output, error: nil, elapsed: 1.0, warm: true)

        guard case let .pass(warnings) = verdict else {
            Issue.record("expected .pass, got \(verdict)")
            return
        }
        #expect(warnings.contains { $0.lowercased().contains("pnpm") })
    }

    @Test func sixSecondsWarnsWarmButNotCold() {
        let warmVerdict = CleanupProbe.verdict(output: recordedGoodOutput, error: nil, elapsed: 6.0, warm: true)
        guard case let .pass(warmWarnings) = warmVerdict else {
            Issue.record("expected .pass, got \(warmVerdict)")
            return
        }
        #expect(warmWarnings.contains { $0.lowercased().contains("elapsed") })

        let coldVerdict = CleanupProbe.verdict(output: recordedGoodOutput, error: nil, elapsed: 6.0, warm: false)
        guard case let .pass(coldWarnings) = coldVerdict else {
            Issue.record("expected .pass, got \(coldVerdict)")
            return
        }
        #expect(coldWarnings.isEmpty)
    }

    @Test func aReasoningLeakFailsNamingTheLeakAndTheModel() {
        let error = CleanupError.reasoningLeaked(model: "qwen3:4b", characters: 20_945)
        let verdict = CleanupProbe.verdict(output: nil, error: error, elapsed: 63.9, warm: false)

        guard case let .fail(reason) = verdict else {
            Issue.record("expected .fail, got \(verdict)")
            return
        }
        #expect(reason.contains("qwen3:4b"))
        #expect(reason.contains("20,945"))
    }

    @Test func a404RemedySaysNotInstalled() {
        let remedy = CleanupProbe.remedy(for: .requestFailed(status: 404, body: "model not found"), elapsed: 0.05)
        #expect(remedy.lowercased().contains("install"))
    }

    @Test func aSlowBackendUnavailableRemedySaysTimedOut() {
        let remedy = CleanupProbe.remedy(for: .backendUnavailable, elapsed: 19.5)
        #expect(remedy.lowercased().contains("timed out"))
    }

    @Test func aFastBackendUnavailableRemedySaysStartOllama() {
        let remedy = CleanupProbe.remedy(for: .backendUnavailable, elapsed: 0.01)
        #expect(remedy.lowercased().contains("start"))
        #expect(remedy.lowercased().contains("ollama"))
    }
}
