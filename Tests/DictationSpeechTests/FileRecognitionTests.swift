import AVFoundation
import Foundation
import Testing
@testable import DictationSpeech

@Suite(.timeLimit(.minutes(1)))
@MainActor struct FileRecognitionTests {
    @Test func aiffFileReachesCleanEOFThroughProductionConverter() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 85194))
            buffer.frameLength = buffer.frameCapacity
            try file.write(from: buffer)
        }
        let capture = FileAudioCapture(url: url, realTime: false)
        let stream = try await capture.start(format: .pcm16Mono16k)
        var bytes = 0
        for try await chunk in stream { bytes += chunk.count }
        await capture.stop()
        #expect(bytes > 120_000)
        #expect(bytes < 124_000)
    }

    @Test func recordedPCMFlowsThroughEngineAndRealReducerBeforeTextEOF() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pcm")
        let pcm = Data((0..<1_386).map { UInt8(truncatingIfNeeded: $0) })
        try pcm.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let socket = TestSocket()
        let engine = SpeechEngine(sessionFactory: { SonioxSession(transport: socket) },
                                  audioFactory: { _ in Issue.record("File recognition opened microphone"); return TestAudio() })
        engine.apiKey = "fixture"
        var finals: [String] = []
        engine.onFinal = { finals.append($0) }
        engine.start(audioFile: file)
        await socket.waitUntilSent(.text(""))
        let frames = await socket.sent
        let sentPCM = frames.reduce(into: Data()) { result, frame in
            if case .binary(let data) = frame { result.append(data) }
        }
        #expect(sentPCM == pcm)
        #expect(frames.last == .text(""))
        #expect(finals.isEmpty)
        await socket.push(.text(#"{"tokens":[{"text":"Recorded result","is_final":true}],"finished":true}"#))
        await engine.runTask?.value
        #expect(finals == ["Recorded result"])
    }

    @Test func malformedRawPCMIsRejectedWithoutFinal() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pcm")
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let audio = FileAudioCapture(url: file)
        await #expect(throws: AppError.self) { _ = try await audio.start(format: .pcm16Mono16k) }
    }

    // Live recognition is verified through the signed app's --audio-file entry point,
    // not an environment-gated skipped test. See README.md and the QA evidence.
}
