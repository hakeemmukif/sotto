import Foundation
import Testing
@testable import Sotto

@Suite("AudioLevel — RMS to a 0...1 meter, no microphone needed")
struct AudioLevelTests {
    @Test func silenceReadsAsZero() {
        // log10(0) is -infinity; normalized(rms: 0) must still land on exactly 0.
        #expect(AudioLevel.normalized(rms: 0) == 0)
    }

    @Test func fullScaleReadsAsOne() {
        #expect(AudioLevel.normalized(rms: 1.0) == 1)
    }

    @Test func fiftyDBDownIsTheFloor() {
        // -50.5 dB, comfortably past the floor rather than sitting exactly on its boundary, so
        // float rounding in the pow/log10 round trip cannot push the result to the wrong side.
        let rms = Float(pow(10.0, -50.5 / 20.0))
        #expect(AudioLevel.normalized(rms: rms) == 0)
    }

    @Test func aLargerRMSNeverReadsLowerAcrossASweep() {
        var previous: Float = 0
        for rms in stride(from: Float(0), through: 1, by: 0.01) {
            let level = AudioLevel.normalized(rms: rms)
            #expect(level >= previous, "rms \(rms) produced \(level), below the previous \(previous)")
            previous = level
        }
    }

    @Test func everyValueClampsToZeroAndOne() {
        for rms: Float in [0.00001, 0.5, 1.0, 2.0, 100.0] {
            let level = AudioLevel.normalized(rms: rms)
            #expect(level >= 0 && level <= 1, "rms \(rms) produced \(level)")
        }
    }
}
