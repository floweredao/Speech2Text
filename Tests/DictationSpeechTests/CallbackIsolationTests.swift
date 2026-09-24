import AVFoundation
import Foundation
import Testing
@testable import DictationSpeech

// Adapted from Speech-to-action/CallbackIsolationTests.swift.
struct CallbackIsolationTests {
    @Test @MainActor func captureTapRunsOffMainAndRejectsLateBuffers() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let pipeline = try AudioPipeline(format: .pcm16Mono16k, input: format)
        let callback = AVAudioCapture.makeTap(pipeline)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                #expect(!Thread.isMainThread)
                let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320)!
                buffer.frameLength = 320
                for index in 0..<320 { buffer.floatChannelData![0][index] = 0.5 }
                callback(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
                pipeline.finish()
                callback(buffer, AVAudioTime(sampleTime: 320, atRate: 16_000))
                continuation.resume()
            }
        }
        var chunks: [Data] = []
        for try await chunk in pipeline.stream { chunks.append(chunk) }
        #expect(chunks == [Data(Array(repeating: [UInt8(0), 64], count: 320).joined())])
    }
}
