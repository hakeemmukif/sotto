import AVFoundation
import Foundation
import Testing
@testable import Sotto

// WAV files AVAudioFile writes carry JUNK/FLLR padding chunks before `data` (verified against
// fixtures/bench.wav, which has its own LIST/INFO chunk in the same spot), so header fields must
// be found by walking chunks rather than assumed at a fixed offset.
private struct WAVHeader {
    let audioFormat: UInt16
    let numChannels: UInt16
    let sampleRate: UInt32
    let bitsPerSample: UInt16
    let dataByteCount: UInt32

    var duration: TimeInterval {
        TimeInterval(dataByteCount) / (TimeInterval(sampleRate) * TimeInterval(numChannels) * TimeInterval(bitsPerSample / 8))
    }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        precondition(data.count >= 12 && data[0..<4] == Data("RIFF".utf8) && data[8..<12] == Data("WAVE".utf8))

        var pos = 12
        var fmt: (UInt16, UInt16, UInt32, UInt16)?
        var dataSize: UInt32?

        while pos + 8 <= data.count {
            let chunkID = data[pos..<(pos + 4)]
            let chunkSize = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: pos + 4, as: UInt32.self) }
            let body = pos + 8

            if chunkID == Data("fmt ".utf8) {
                let audioFormat = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: body, as: UInt16.self) }
                let numChannels = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: body + 2, as: UInt16.self) }
                let sampleRate = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: body + 4, as: UInt32.self) }
                let bitsPerSample = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: body + 14, as: UInt16.self) }
                fmt = (audioFormat, numChannels, sampleRate, bitsPerSample)
            } else if chunkID == Data("data".utf8) {
                dataSize = chunkSize
            }

            pos = body + Int(chunkSize) + (chunkSize % 2 == 1 ? 1 : 0)
        }

        guard let fmt, let dataSize else {
            throw AudioRecorderError.fileCreationFailed("no fmt/data chunk found in \(url.path)")
        }
        (audioFormat, numChannels, sampleRate, bitsPerSample) = fmt
        dataByteCount = dataSize
    }
}

private func makeSyntheticBuffer(format: AVAudioFormat, seconds: Double, frequency: Double = 440) -> AVAudioPCMBuffer {
    let frameCount = AVAudioFrameCount((seconds * format.sampleRate).rounded())
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    for channel in 0..<Int(format.channelCount) {
        let samples = buffer.floatChannelData![channel]
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / format.sampleRate
            samples[frame] = Float(sin(2 * .pi * frequency * t) * 0.5)
        }
    }
    return buffer
}

// MARK: - Format-correctness tests (no microphone required)
//
// These drive AudioConversionPipeline directly with synthesized AVAudioPCMBuffers, bypassing
// AVAudioEngine and the input node entirely. Microphone access has not been granted on this
// machine, so anything touching AudioRecorder.start()/stop() is quarantined below instead.

@Test func oneSecondRecordingProducesA16kHzMonoWAV() throws {
    let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let pipeline = try AudioConversionPipeline(
        inputFormat: inputFormat,
        targetFormat: AudioRecorder.targetFormat,
        minimumDuration: AudioRecorder.minimumDuration
    )
    defer { try? FileManager.default.removeItem(at: pipeline.url) }

    for _ in 0..<10 {
        try pipeline.append(makeSyntheticBuffer(format: inputFormat, seconds: 0.1))
    }

    let url = try pipeline.finish()
    let producedURL = try #require(url)
    #expect(producedURL == pipeline.url)

    let header = try WAVHeader(contentsOf: producedURL)
    #expect(header.audioFormat == 1) // PCM
    #expect(header.sampleRate == 16_000)
    #expect(header.numChannels == 1)
    #expect(header.bitsPerSample == 16)
    #expect(abs(header.duration - 1.0) < 0.05)
}

@Test func hundredMillisecondRecordingReturnsNilAndWritesNoFile() throws {
    let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let pipeline = try AudioConversionPipeline(
        inputFormat: inputFormat,
        targetFormat: AudioRecorder.targetFormat,
        minimumDuration: AudioRecorder.minimumDuration
    )

    try pipeline.append(makeSyntheticBuffer(format: inputFormat, seconds: 0.1))

    let url = try pipeline.finish()
    #expect(url == nil)
    #expect(!FileManager.default.fileExists(atPath: pipeline.url.path))
}

@Test func unsupportedInputFormatThrowsRatherThanGuessing() throws {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 0,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 0,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    let bogusFormat = try #require(AVAudioFormat(streamDescription: &asbd))

    #expect(throws: AudioRecorderError.unsupportedInputFormat) {
        try AudioConversionPipeline(
            inputFormat: bogusFormat,
            targetFormat: AudioRecorder.targetFormat,
            minimumDuration: AudioRecorder.minimumDuration
        )
    }
}

// MARK: - Live microphone path
//
// Not testable on this machine: microphone access has not been granted to anything here yet, and
// granting it requires an interactive TCC dialog this environment cannot drive. AVAudioEngine's
// input node under these conditions returns silence or fails outright, so any assertion here would
// either be a false green (a rejected 300 ms floor that never captured real audio) or flake on
// whatever partial permission state happens to be present. Left disabled rather than deleted so the
// live path is visibly unproven, not silently skipped.

@Test(.disabled("requires microphone (TCC) permission not grantable on this machine"))
func liveRecordingProducesAWAVFile() throws {
    let recorder = AudioRecorder()
    try recorder.start()
    Thread.sleep(forTimeInterval: 1.0)
    let url = try recorder.stop()
    #expect(url != nil)
}
