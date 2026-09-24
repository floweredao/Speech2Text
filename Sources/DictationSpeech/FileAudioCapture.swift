import AVFoundation
import Foundation

/// Pull-based file input uses the same converter and wire format as microphone capture.
/// Raw .pcm files must be signed 16-bit little-endian, mono, 16 kHz.
@MainActor final class FileAudioCapture: AudioCapturing {
    private let url: URL
    private let maximumSeconds: Double
    private var rawFile: FileHandle?
    private var audioFile: AVAudioFile?
    private var converter: PCMConverter?
    private var stopped = false

    init(url: URL, maximumSeconds: Double = 60) {
        self.url = url
        self.maximumSeconds = maximumSeconds
    }

    func start(format: CaptureFormat) async throws -> AsyncThrowingStream<Data, Error> {
        try Task.checkCancellation()
        guard url.isFileURL else { throw AppError.invalidResponse("Expected local audio file") }
        if url.pathExtension.lowercased() == "pcm" {
            let file = try FileHandle(forReadingFrom: url)
            let bytes = try file.seekToEnd()
            guard bytes > 0, bytes.isMultiple(of: 2), Double(bytes) <= maximumSeconds * 32_000 else {
                try file.close()
                throw AppError.invalidResponse("PCM must contain 1 to 60 seconds of 16 kHz mono s16le audio")
            }
            try file.seek(toOffset: 0)
            rawFile = file
        } else {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, file.processingFormat.sampleRate > 0,
                  Double(file.length) / file.processingFormat.sampleRate <= maximumSeconds else {
                throw AppError.invalidResponse("Audio file exceeds recording limit or is empty")
            }
            audioFile = file
            converter = try PCMConverter(input: file.processingFormat, format: format)
        }
        return AsyncThrowingStream(unfolding: { [weak self] in
            try await self?.nextChunk()
        })
    }

    private func nextChunk() throws -> Data? {
        try Task.checkCancellation()
        guard !stopped else { return nil }
        if let rawFile {
            let data = try rawFile.read(upToCount: 640) ?? Data()
            return data.isEmpty ? nil : data
        }
        guard let audioFile, let converter else { return nil }
        let remaining = audioFile.length - audioFile.framePosition
        guard remaining > 0 else { return nil }
        let frames = AVAudioFrameCount(min(remaining, AVAudioFramePosition(max(1, audioFile.processingFormat.sampleRate / 50))))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frames) else {
            throw AppError.invalidResponse("Audio file buffer allocation")
        }
        try audioFile.read(into: buffer, frameCount: frames)
        guard buffer.frameLength > 0 else { return nil }
        return try converter.convert(buffer)
    }

    func stop() async {
        stopped = true
        try? rawFile?.close()
        rawFile = nil
        audioFile = nil
        converter = nil
    }
}
