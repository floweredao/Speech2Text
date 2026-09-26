// Adapted from Speech-to-action; speech-only module, no command execution.
import AVFoundation
import Foundation

final class PCMConverter {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    init(input: AVAudioFormat, format: CaptureFormat) throws {
        let rate: Double = 16_000
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw AppError.invalidResponse("Unsupported microphone format")
        }
        self.output = output; self.converter = converter
        converter.primeMethod = .none
        converter.downmix = true
    }
    func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate)) + 32
        guard let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            throw AppError.invalidResponse("PCM output allocation")
        }
        let feeder = PCMInputFeeder(buffer)
        var error: NSError?
        let status = converter.convert(to: result, error: &error) { count, inputStatus in
            let next = feeder.next(count)
            inputStatus.pointee = next == nil ? .noDataNow : .haveData
            return next
        }
        guard status != .error, error == nil, let samples = result.int16ChannelData else {
            throw AppError.invalidResponse("Microphone PCM conversion")
        }
        // macOS runs little-endian; serialize explicitly so wire format stays unambiguous.
        var data = Data(capacity: Int(result.frameLength) * 2)
        for index in 0..<Int(result.frameLength) {
            let value = UInt16(bitPattern: samples[0][index])
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return data
    }
}

// AVAudioEngine invokes its tap off actor. Every mutable field and converter access
// is serialized by this lock; buffers never escape the callback that owns them.
final class AudioPipeline: @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var converter: PCMConverter?
    private var pending = Data()
    private var finished = false
    private let chunkBytes: Int
    init(format: CaptureFormat, input: AVAudioFormat? = nil, capacity: Int = 100) throws {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(capacity))
        stream = pair.stream; continuation = pair.continuation
        chunkBytes = 640
        if let input { converter = try PCMConverter(input: input, format: format) }
    }
    func onTermination(_ callback: @escaping @Sendable () -> Void) {
        continuation.onTermination = { _ in callback() }
    }
    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, let converter else { return }
        do { try enqueue(converter.convert(buffer)) }
        catch { finished = true; pending.removeAll(); continuation.finish(throwing: error) }
    }
    func receivePCM(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        do { try enqueue(data) }
        catch { finished = true; pending.removeAll(); continuation.finish(throwing: error) }
    }
    private func enqueue(_ data: Data) throws {
        pending.append(data)
        while pending.count >= chunkBytes {
            let chunk = Data(pending.prefix(chunkBytes))
            pending.removeFirst(chunkBytes)
            if case .dropped = continuation.yield(chunk) { throw AppError.audioOverflow }
        }
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if !pending.isEmpty, case .dropped = continuation.yield(pending) {
            continuation.finish(throwing: AppError.audioOverflow)
        } else { continuation.finish() }
        pending.removeAll()
    }
}

@MainActor final class AVAudioCapture: AudioCapturing {
    private var engine: AVAudioEngine?
    private var pipeline: AudioPipeline?
    private var generation = UUID()
    private let deviceUID: String?
    init(deviceUID: String? = nil) { self.deviceUID = deviceUID }
    func start(format: CaptureFormat) async throws -> AsyncThrowingStream<Data, Error> {
        await stop()
        let id = UUID(); generation = id
        let permitted = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard generation == id else { throw AppError.cancelled }
        guard permitted else { throw AppError.permissionDenied("Microphone") }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        if let deviceUID {
            guard var device = AudioInputDevices.deviceID(forUID: deviceUID), let unit = node.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            else { throw AppError.inputDeviceUnavailable }
        }
        let input = node.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else { throw AppError.permissionDenied("Microphone input device") }
        let pipeline = try AudioPipeline(format: format, input: input)
        self.engine = engine; self.pipeline = pipeline
        pipeline.onTermination { [weak self] in
            Task { @MainActor in
                guard self?.generation == id else { return }
                await self?.stop()
            }
        }
        node.installTap(onBus: 0, bufferSize: 960, format: input, block: Self.makeTap(pipeline))
        do { engine.prepare(); try engine.start() }
        catch { await stop(); throw AppError.permissionDenied("Microphone could not start") }
        return pipeline.stream
    }
    nonisolated static func makeTap(_ pipeline: AudioPipeline) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in pipeline.receive(buffer) }
    }
    isolated deinit {
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        pipeline?.finish()
    }
    func stop() async {
        generation = UUID()
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0); engine.reset() }
        engine = nil
        pipeline?.finish(); pipeline = nil
    }
}

// The converter calls this synchronously. The lock also satisfies its Sendable
// callback contract; input buffers are read-only for the duration of conversion.
private final class PCMInputFeeder: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var offset: AVAudioFrameCount = 0
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next(_ requested: AVAudioPacketCount) -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        let count = min(requested, buffer.frameLength - offset)
        guard count > 0, let result = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else { return nil }
        result.frameLength = count
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        let stride = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        for index in 0..<source.count {
            if let from = source[index].mData, let to = destination[index].mData {
                to.copyMemory(from: from.advanced(by: Int(offset) * stride), byteCount: Int(count) * stride)
            }
        }
        offset += count
        return result
    }
}
