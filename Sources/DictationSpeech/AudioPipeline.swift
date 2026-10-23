import AVFoundation
import os
import Foundation

final class PCMConverter {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    let input: AVAudioFormat
    init(input: AVAudioFormat, format: CaptureFormat) throws {
        self.input = input
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
    private var heardSignal = false
    private var receivedBytes = 0
    private var level: Float = 0
    /// Peak of the latest received audio, 0-1.
    var inputLevel: Float { lock.lock(); defer { lock.unlock() }; return level }
    /// Seconds of 16 kHz mono 16-bit audio received so far.
    var capturedDuration: TimeInterval { lock.lock(); defer { lock.unlock() }; return Double(receivedBytes) / 32_000 }
    private var signalWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var terminalError: Error?
    /// The error that ended the stream early, if any.
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return terminalError }
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
        guard !finished, var converter else { return }
        do {
            // Bluetooth microphones drop to a lower rate once their input opens; follow the hardware.
            if converter.input != buffer.format {
                converter = try PCMConverter(input: buffer.format, format: .pcm16Mono16k)
                self.converter = converter
            }
            try enqueue(converter.convert(buffer))
        }
        catch { end(throwing: error) }
    }
    func receivePCM(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        do { try enqueue(data) }
        catch { end(throwing: error) }
    }
    /// Caller holds the lock.
    private func end(throwing error: Error) {
        finished = true
        terminalError = error
        pending.removeAll()
        continuation.finish(throwing: error)
        resumeWaiters()
    }
    private func enqueue(_ data: Data) throws {
        if !heardSignal, data.contains(where: { $0 != 0 }) {
            heardSignal = true
            resumeWaiters()
        }
        receivedBytes += data.count
        level = Self.peak(data)
        pending.append(data)
        while pending.count >= chunkBytes {
            let chunk = Data(pending.prefix(chunkBytes))
            pending.removeFirst(chunkBytes)
            if case .dropped = continuation.yield(chunk) { throw AppError.audioOverflow }
        }
    }
    private static func peak(_ data: Data) -> Float {
        var peak: Int32 = 0
        data.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) { peak = max(peak, abs(Int32(Int16(littleEndian: sample)))) }
        }
        return Float(peak) / Float(Int16.max)
    }

    /// True once audio other than digital silence arrives. A refused or dead device never gets there.
    func waitForSignal(timeout: Duration) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if heardSignal || finished {
                let heard = heardSignal
                lock.unlock()
                continuation.resume(returning: heard)
                return
            }
            signalWaiters[id] = continuation
            lock.unlock()
            let parts = timeout.components
            let delay = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.expireWaiter(id) }
        }
    }
    private func expireWaiter(_ id: UUID) {
        lock.lock()
        let waiter = signalWaiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume(returning: false)
    }
    private func resumeWaiters() {
        let waiters = signalWaiters.values
        signalWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: heardSignal) }
    }
    func fail(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        end(throwing: error)
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        resumeWaiters()
        if !pending.isEmpty, case .dropped = continuation.yield(pending) {
            continuation.finish(throwing: AppError.audioOverflow)
        } else { continuation.finish() }
        pending.removeAll()
    }
}

/// Records from one device through its own HAL unit. AVAudioEngine's input node follows the system default
/// input and moved back to it when a Bluetooth headset reconfigured, so a chosen microphone did not stay chosen.
@MainActor final class HALAudioCapture: AudioCapturing {
    private static let log = Logger(subsystem: "local.speech2text.app", category: "audio")
    private var unit: AudioUnit?
    private var renderer: HALInputRenderer?
    private var pipeline: AudioPipeline?
    private var generation = UUID()
    private var deviceObservation: AudioDeviceAliveObservation?
    private var formatObservation: HALFormatObservation?
    private let deviceUID: String?
    init(deviceUID: String? = nil) { self.deviceUID = deviceUID }
    var promptsForPermission: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined }
    var capturedDuration: TimeInterval { pipeline?.capturedDuration ?? 0 }
    var inputLevel: Float { pipeline?.inputLevel ?? 0 }
    func start(format: CaptureFormat) async throws -> AsyncThrowingStream<Data, Error> {
        await stop()
        let id = UUID(); generation = id
        let permitted = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard generation == id else { throw AppError.cancelled }
        guard permitted else { throw AppError.permissionDenied("Microphone") }
        // The device is fixed for the whole recording; a later change of the system default does not move it.
        guard let device = deviceUID.map(AudioInputDevices.deviceID(forUID:)) ?? AudioInputDevices.defaultDeviceID()
        else { throw AppError.inputDeviceUnavailable }
        let name = AudioInputDevices.name(of: device) ?? deviceUID ?? "?"
        let unit: AudioUnit
        let input: AVAudioFormat
        do { (unit, input) = try Self.makeUnit(device: device) }
        catch let status as HALStatus { throw AppError.microphoneStartFailed(device: name, status: status.code) }
        let pipeline = try AudioPipeline(format: format, input: input, capacity: 600)
        let renderer = HALInputRenderer(unit: unit, deliver: Self.makeTap(pipeline))
        self.unit = unit; self.renderer = renderer; self.pipeline = pipeline
        pipeline.onTermination { [weak self] in
            Task { @MainActor in
                guard self?.generation == id else { return }
                await self?.stop()
            }
        }
        var callback = AURenderCallbackStruct(inputProc: HALInputRenderer.inputProc,
                                              inputProcRefCon: Unmanaged.passUnretained(renderer).toOpaque())
        var status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                          &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        if status == noErr { status = AudioUnitInitialize(unit) }
        if status == noErr { status = AudioOutputUnitStart(unit) }
        guard status == noErr else {
            Self.log.error("start failed on \(name, privacy: .public): \(status, privacy: .public)")
            await stop()
            throw AppError.microphoneStartFailed(device: name, status: status)
        }
        formatObservation = HALFormatObservation(unit) { [weak self] in
            guard self?.generation == id else { return }
            self?.followHardwareFormat(name: name)
        }
        // Unplugging the device ends the recording instead of leaving it silent.
        deviceObservation = AudioDeviceAliveObservation(device) { [weak self] in
            guard self?.generation == id else { return }
            Self.log.notice("input device disappeared")
            self?.pipeline?.fail(AppError.microphoneInterrupted)
        }
        let heard = await pipeline.waitForSignal(timeout: .seconds(3))
        guard generation == id else { throw AppError.cancelled }
        guard heard else {
            let failure = pipeline.failure
            await stop()
            throw failure ?? AppError.microphoneSilent
        }
        return pipeline.stream
    }
    /// A Bluetooth headset switches to its call profile once its microphone opens, changing the rate after start.
    /// The unit cannot resample input, so the client side is set to the new rate and the unit restarted.
    private func followHardwareFormat(name: String) {
        guard let unit else { return }
        var hardware = AudioStreamBasicDescription(), client = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size) == noErr,
              AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, &size) == noErr,
              hardware.mSampleRate > 0, hardware.mSampleRate != client.mSampleRate
                || hardware.mChannelsPerFrame != client.mChannelsPerFrame else { return }
        Self.log.notice("input format changed to \(hardware.mSampleRate, privacy: .public) Hz")
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        var status = kAudioUnitErr_FormatNotSupported
        if let format = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame) {
            var description = format.streamDescription.pointee
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &description, size)
        }
        if status == noErr { status = AudioUnitInitialize(unit) }
        if status == noErr { status = AudioOutputUnitStart(unit) }
        if status != noErr { pipeline?.fail(AppError.microphoneStartFailed(device: name, status: status)) }
    }
    private struct HALStatus: Error { let code: OSStatus }
    private static func makeUnit(device: AudioDeviceID) throws -> (AudioUnit, AVAudioFormat) {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw HALStatus(code: kAudioUnitErr_NoConnection) }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created))
        guard let unit = created else { throw HALStatus(code: kAudioUnitErr_NoConnection) }
        do {
            var on: UInt32 = 1, off: UInt32 = 0, device = device
            let flag = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flag))
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flag))
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &device, UInt32(MemoryLayout<AudioDeviceID>.size)))
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size))
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let client = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate,
                                             channels: hardware.mChannelsPerFrame)
            else { throw HALStatus(code: kAudioUnitErr_FormatNotSupported) }
            // The HAL unit converts the device's samples to float at the device rate; it never resamples input.
            var clientDescription = client.streamDescription.pointee
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                           &clientDescription, size))
            return (unit, client)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }
    private static func check(_ status: OSStatus) throws { if status != noErr { throw HALStatus(code: status) } }
    nonisolated static func makeTap(_ pipeline: AudioPipeline) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in pipeline.receive(buffer) }
    }
    isolated deinit {
        if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        pipeline?.finish()
    }
    func stop() async {
        generation = UUID()
        deviceObservation = nil
        formatObservation = nil
        if let unit { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        unit = nil
        renderer = nil
        pipeline?.finish(); pipeline = nil
    }
}

/// Reports stream format changes of a HAL unit's input on the main thread.
final class HALFormatObservation: @unchecked Sendable {
    private let unit: AudioUnit
    private let onChange: @MainActor () -> Void
    init(_ unit: AudioUnit, _ onChange: @escaping @MainActor () -> Void) {
        self.unit = unit; self.onChange = onChange
        AudioUnitAddPropertyListener(unit, kAudioUnitProperty_StreamFormat, Self.listener,
                                     Unmanaged.passUnretained(self).toOpaque())
    }
    deinit {
        AudioUnitRemovePropertyListenerWithUserData(unit, kAudioUnitProperty_StreamFormat, Self.listener,
                                                    Unmanaged.passUnretained(self).toOpaque())
    }
    private static let listener: AudioUnitPropertyListenerProc = { refCon, _, _, scope, element in
        guard scope == kAudioUnitScope_Input, element == 1 else { return }
        let observation = Unmanaged<HALFormatObservation>.fromOpaque(refCon).takeUnretainedValue()
        let onChange = observation.onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { onChange() } }
    }
}

/// Pulls each input slice on the audio I/O thread and hands a copy to the pipeline on a serial queue.
/// The stream format is read per slice, so a Bluetooth rate change after start reaches the converter.
final class HALInputRenderer: @unchecked Sendable {
    private let unit: AudioUnit
    private let deliver: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    private let queue = DispatchQueue(label: "local.speech2text.audio-input")
    /// Ownership passes to the queue: the I/O thread never touches a slice after handing it over.
    private struct Slice: @unchecked Sendable { let buffer: AVAudioPCMBuffer; let time: AVAudioTime }
    init(unit: AudioUnit, deliver: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        self.unit = unit; self.deliver = deliver
    }
    static let inputProc: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
        Unmanaged<HALInputRenderer>.fromOpaque(refCon).takeUnretainedValue().render(flags, timestamp, bus, frames)
    }
    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timestamp: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &description, &size)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &description),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return status }
        buffer.frameLength = frames
        status = AudioUnitRender(unit, flags, timestamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        let slice = Slice(buffer: buffer, time: AVAudioTime(audioTimeStamp: timestamp, sampleRate: format.sampleRate))
        queue.async { [deliver] in deliver(slice.buffer, slice.time) }
        return noErr
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
