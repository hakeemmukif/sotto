@preconcurrency import AVFoundation

enum AudioRecorderError: Error, Equatable {
    case alreadyRecording
    case notRecording
    case unsupportedInputFormat
    case converterCreationFailed
    case bufferCopyFailed
    case conversionFailed(String)
    case conversionFailedWithoutDetail
    case fileCreationFailed(String)
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

    private let engine = AVAudioEngine()
    private var pipeline: AudioConversionPipeline?
    private var captureError: Error?
    private(set) var isRecording = false

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
