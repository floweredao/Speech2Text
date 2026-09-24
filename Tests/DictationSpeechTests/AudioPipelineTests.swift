import AVFoundation
import Foundation
import Testing
@testable import DictationSpeech


struct AudioPipelineTests {
    @Test func monoSampleValuesAndByteOrder() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try #require(buffer.floatChannelData)[0]
        samples[0] = 0; samples[1] = 0.5; samples[2] = -0.5; samples[3] = -1
        let data = try PCMConverter(input: format, format: .pcm16Mono16k).convert(buffer)
        #expect(Array(data) == [0, 0, 0, 64, 0, 192, 0, 128])
    }
    @Test func ratesAndStereoDownmix() throws {
        let output = CaptureFormat.pcm16Mono16k
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let samples = try #require(buffer.floatChannelData)
        for index in 0..<4_800 { samples[0][index] = 0.25; samples[1][index] = 0.75 }
        let data = try PCMConverter(input: format, format: output).convert(buffer)
        let expected = 3_200
        #expect(data.count == expected)
        #expect(data.suffix(2) == Data([0, 64]))
    }
}

extension AudioPipelineTests {
    @Test func boundedOverflowIsExplicit() async throws {
        let pipeline = try AudioPipeline(format: .pcm16Mono16k, capacity: 2)
        pipeline.receivePCM(Data(repeating: 7, count: 640 * 3))
        var iterator = pipeline.stream.makeAsyncIterator()
        #expect(try await iterator.next() == Data(repeating: 7, count: 640))
        #expect(try await iterator.next() == Data(repeating: 7, count: 640))
        await #expect(throws: AppError.audioOverflow) { _ = try await iterator.next() }
    }
    @Test func stopDrainsAndRejectsLateCallback() async throws {
        let pipeline = try AudioPipeline(format: .pcm16Mono16k)
        pipeline.receivePCM(Data(repeating: 3, count: 640 + 100))
        pipeline.finish()
        pipeline.receivePCM(Data(repeating: 9, count: 640))
        pipeline.finish()
        var chunks: [Data] = []
        for try await chunk in pipeline.stream { chunks.append(chunk) }
        #expect(chunks == [Data(repeating: 3, count: 640), Data(repeating: 3, count: 100)])
    }
    @Test func actualTwoSecondBound() async throws {
        let pipeline = try AudioPipeline(format: .pcm16Mono16k)
        pipeline.receivePCM(Data(repeating: 0, count: 640 * 101))
        var count = 0
        do {
            for try await _ in pipeline.stream { count += 1 }
            Issue.record("Overflow must throw")
        } catch { #expect(error as? AppError == .audioOverflow) }
        #expect(count == 100)
    }
    @Test func chunkedResamplingKeepsFrameTotals() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        buffer.frameLength = 960
        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0..<960 { samples[index] = -0.5 }
        let converter = try PCMConverter(input: format, format: .pcm16Mono16k)
        var data = Data()
        for _ in 0..<10 { data.append(try converter.convert(buffer)) }
        #expect(data.count == 6_400)
        #expect(data.suffix(2) == Data([0, 192]))
    }
}
