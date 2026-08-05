import AVFoundation
import Foundation

enum TranscriberError: Error, Equatable {
    case whisperBinaryMissing(String)
    case modelMissing(String)
    case whisperFailed(exitCode: Int32, stderr: String)
    case whisperFailedWithoutDetail(exitCode: Int32)
    case warmUpClipAllocationFailed
    case emptyTranscript
}

struct Transcriber {
    let binaryPath: String
    let modelPath: String

    init(binaryPath: String, modelPath: String) {
        self.binaryPath = (binaryPath as NSString).expandingTildeInPath
        self.modelPath = (modelPath as NSString).expandingTildeInPath
    }

    // The first inference after login pulls 1.4 GB of model through an empty page cache: measured
    // 8.44 s cold against 0.91 s warm on 2026-08-05. One throwaway inference at launch moves that
    // cost off the user's first dictation. Its output is discarded — silence has no transcript, so
    // this deliberately bypasses the empty-transcript check in `transcribe`.
    func warmUp() throws {
        let clip = try silentClip()
        defer { try? FileManager.default.removeItem(at: clip) }
        _ = try run(wav: clip, vocabularyPrompt: nil)
    }

    func transcribe(_ wav: URL, vocabularyPrompt: String?) throws -> String {
        let transcript = try run(wav: wav, vocabularyPrompt: vocabularyPrompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw TranscriberError.emptyTranscript }
        return transcript
    }

    private func run(wav: URL, vocabularyPrompt: String?) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw TranscriberError.whisperBinaryMissing(binaryPath)
        }
        guard FileManager.default.isReadableFile(atPath: modelPath) else {
            throw TranscriberError.modelMissing(modelPath)
        }

        var arguments = ["-m", modelPath, "-f", wav.path, "-np", "-nt"]
        if let vocabularyPrompt {
            arguments.append(contentsOf: ["--prompt", vocabularyPrompt])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        // whisper-cli writes several KB of model detail to stderr. Draining it on another thread
        // keeps a full pipe buffer from deadlocking against the stdout read.
        nonisolated(unsafe) var errorData = Data()
        let draining = DispatchGroup()
        DispatchQueue.global().async(group: draining) {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        draining.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stderr.isEmpty else {
                throw TranscriberError.whisperFailedWithoutDetail(exitCode: process.terminationStatus)
            }
            throw TranscriberError.whisperFailed(exitCode: process.terminationStatus, stderr: stderr)
        }
        return String(decoding: outputData, as: UTF8.self)
    }

    private func silentClip() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sotto-warmup-\(UUID().uuidString).wav")
        let format = AudioRecorder.targetFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000) else {
            throw TranscriberError.warmUpClipAllocationFailed
        }
        buffer.frameLength = 8_000
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try file.write(from: buffer)
        return url
    }
}
