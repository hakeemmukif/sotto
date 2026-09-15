@preconcurrency import AVFoundation
import Foundation

enum AudioRecorderError: Error, Equatable, CustomStringConvertible {
    case alreadyRecording
    case notRecording
    case unsupportedInputFormat
    case converterCreationFailed
    case bufferCopyFailed
    case conversionFailed(String)
    case conversionFailedWithoutDetail
    case fileCreationFailed(String)

    var description: String {
        switch self {
        case .alreadyRecording:
            "already recording; stop the current recording before starting another"
        case .notRecording:
            "not recording; there is nothing to stop"
        case .unsupportedInputFormat:
            "the input device reported no sample rate or no channels"
        case .converterCreationFailed:
            "could not create an audio converter to the 16 kHz mono target format"
        case .bufferCopyFailed:
            "could not copy an audio buffer for later conversion"
        case let .conversionFailed(detail):
            "audio conversion failed: \(detail)"
        case .conversionFailedWithoutDetail:
            "audio conversion failed with nothing reported"
        case let .fileCreationFailed(detail):
            "could not write the recording to disk: \(detail)"
        }
    }
}

/// The pill's level meter, in dBFS mapped onto 0...1. A pure function, not a method on
/// `AudioRecorder`, so it is unit-testable without a microphone.
enum AudioLevel {
    // Measured 2026-09-16: dictation speech sits comfortably above a quiet room's noise floor, so
    // -50 dBFS reads as silence and the bar only lifts once there is real signal.
    private static let floorDB: Float = -50

    static func normalized(rms: Float) -> Float {
        // log10(0) is -infinity, not an error — silence is a real reading, not a failed one — and
        // it would clamp to the same 0 the floor produces anyway, so it is short-circuited instead.
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(max((db - floorDB) / -floorDB, 0), 1)
    }
}

// Buffers arrive from the tap in whatever chunk size AVAudioEngine hands over, but AVAudioConverter
// only reports the true output length once it has been told the input has ended: an intermediate
// `.noDataNow` leaves the resampler's filter tail unflushed and the last ~1/16 s of every clip
// missing. So raw buffers are copied and held, then converted in a single pass at `finish()`,
// signalling `.endOfStream` on the final pull. Measured 2026-08-05: incremental per-chunk
// conversion with `.noDataNow` undershot a 1.0 s clip by 60 ms; a single pass ending in
// `.endOfStream` landed exactly on 16000 output frames.
final class AudioConversionPipeline {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let minimumDuration: TimeInterval
    private let inputSampleRate: Double
    private var inputBuffers: [AVAudioPCMBuffer] = []
    private var inputFrameCount: AVAudioFrameCount = 0
    let url: URL

    init(inputFormat: AVAudioFormat, targetFormat: AVAudioFormat, minimumDuration: TimeInterval) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.unsupportedInputFormat
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterCreationFailed
        }
        self.converter = converter
        self.targetFormat = targetFormat
        self.minimumDuration = minimumDuration
        self.inputSampleRate = inputFormat.sampleRate
        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sotto-\(UUID().uuidString).wav")
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else {
            throw AudioRecorderError.bufferCopyFailed
        }
        inputBuffers.append(copy)
        inputFrameCount += buffer.frameLength
    }

    func finish() throws -> URL? {
        let duration = Double(inputFrameCount) / inputSampleRate
        guard duration >= minimumDuration else { return nil }

        let ratio = targetFormat.sampleRate / inputSampleRate
        let capacity = AVAudioFrameCount(Double(inputFrameCount) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw AudioRecorderError.conversionFailed("could not allocate the output buffer")
        }

        // AVAudioConverter's input block is imported as @Sendable, but convert(to:error:withInputFrom:)
        // calls it synchronously and only on the calling thread — this mutation never races.
        nonisolated(unsafe) var index = 0
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [inputBuffers] _, inputStatus in
            guard index < inputBuffers.count else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            let buffer = inputBuffers[index]
            index += 1
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            guard let conversionError else { throw AudioRecorderError.conversionFailedWithoutDetail }
            throw AudioRecorderError.conversionFailed(conversionError.localizedDescription)
        }

        // AVAudioFile finalizes the RIFF/data chunk sizes only once its last strong reference is
        // released, not on the final `write(from:)`. Explicitly dropping `file` here forces that
        // before the URL is handed back, so a caller reading it immediately sees a complete header.
        var file: AVAudioFile?
        do {
            file = try AVAudioFile(forWriting: url, settings: targetFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            try file!.write(from: output)
        } catch {
            file = nil
            throw AudioRecorderError.fileCreationFailed("\(error)")
        }
        file = nil
        return url
    }
}

final class AudioRecorder {
    static let targetFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true) else {
            fatalError("could not construct the 16 kHz mono Int16 audio format")
        }
        return format
    }()

    static let minimumDuration: TimeInterval = 0.3

    // 20 Hz is plenty for a meter bar to look continuous, and the tap fires far more often than
    // that — hopping to main for every 1024-sample buffer would be wasted work the UI never sees.
    private static let levelInterval: TimeInterval = 1.0 / 20.0

    private let engine = AVAudioEngine()
    private let onLevel: @Sendable (Float) -> Void
    private var pipeline: AudioConversionPipeline?
    private var captureError: Error?
    private var lastLevelEmit = Date.distantPast
    private(set) var isRecording = false

    // Required, not defaulted: a caller that forgets to wire it up gets a silently dead meter, which
    // is the exact bug this type exists to fix.
    init(onLevel: @escaping @Sendable (Float) -> Void) {
        self.onLevel = onLevel
    }

    func start() throws {
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let pipeline = try AudioConversionPipeline(
            inputFormat: inputFormat,
            targetFormat: Self.targetFormat,
            minimumDuration: Self.minimumDuration
        )
        captureError = nil

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            do {
                try pipeline.append(buffer)
            } catch {
                self?.captureError = error
            }

            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastLevelEmit) >= Self.levelInterval else { return }
            self.lastLevelEmit = now

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            var sumOfSquares: Float = 0
            for i in 0..<frameLength { sumOfSquares += channelData[i] * channelData[i] }
            let rms = sqrt(sumOfSquares / Float(frameLength))
            let level = AudioLevel.normalized(rms: rms)
            let onLevel = self.onLevel
            DispatchQueue.main.async { onLevel(level) }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }

        self.pipeline = pipeline
        isRecording = true
    }

    func stop() throws -> URL? {
        guard isRecording, let pipeline else { throw AudioRecorderError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        self.pipeline = nil

        if let error = captureError {
            captureError = nil
            throw error
        }

        return try pipeline.finish()
    }
}
