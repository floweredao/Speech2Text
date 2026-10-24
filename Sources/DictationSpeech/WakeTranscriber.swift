import AVFoundation
import Foundation
import Speech
import os

/// The listener's view of `WakeTranscriber`, which exists only on macOS 26 and later.
protocol WakeTranscribing: Sendable {
    var localeName: String { get }
    func accept(pcm: Data)
    func finish() async
    func cancel() async
}

/// Hears the wake phrase through macOS's own on-device speech recognition, next to the English keyword model.
/// The keyword model knows only English sounds and almost never hears "헤이 컴퓨터" said with a Korean accent; the
/// system recognizer for the user's language writes it down ("헤이 컴퓨터", "에이 컴퓨터"), and `matches` decides
/// whether the written words hold the phrase. Audio stays on this Mac. Needs macOS 26 and an installed language.
@available(macOS 26, *)
final class WakeTranscriber: WakeTranscribing, @unchecked Sendable {
    private static let log = Logger(subsystem: "local.speech2text.app", category: "wake-word")
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let reading: Task<Void, Never>
    let locale: Locale
    var localeName: String { locale.identifier(.bcp47) }

    /// nil when no preferred language of the user has an installed on-device recognizer. A non-English language comes
    /// first: the keyword model already hears English speakers, and an English recognizer writes the Korean "헤이 컴퓨터"
    /// as "A computer", which is too common to wake on.
    static func make(matches: @escaping @Sendable (String) -> Bool, onMatch: @escaping @Sendable () async -> Void) async -> WakeTranscriber? {
        guard SpeechTranscriber.isAvailable else { return nil }
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        var locale: Locale?
        let languages = Locale.preferredLanguages
        for language in languages.filter({ !$0.hasPrefix("en") }) + languages.filter({ $0.hasPrefix("en") }) {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)),
               installed.contains(supported.identifier(.bcp47)) {
                locale = supported
                break
            }
        }
        guard let locale else {
            log.notice("no installed on-device recognizer for \(Locale.preferredLanguages, privacy: .public)")
            return nil
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }
        return try? await WakeTranscriber(transcriber: transcriber, locale: locale, format: format, matches: matches,
                                          onMatch: onMatch)
    }

    private init(transcriber: SpeechTranscriber, locale: Locale, format: AVAudioFormat,
                 matches: @escaping @Sendable (String) -> Bool, onMatch: @escaping @Sendable () async -> Void) async throws {
        self.locale = locale
        self.format = format
        converter = format == source ? nil : AVAudioConverter(from: source, to: format)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = input
        analyzer = SpeechAnalyzer(modules: [transcriber])
        reading = Task.detached(priority: .utility) {
            do {
                for try await result in transcriber.results where matches(String(result.text.characters)) {
                    await onMatch()
                }
            } catch {
                Self.log.error("recognizer stopped: \(String(describing: error), privacy: .public)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Feeds 16 kHz mono 16-bit little-endian audio.
    func accept(pcm: Data) {
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            buffer.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
        }
        guard let converter else {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let capacity = AVAudioFrameCount(Double(frames) * format.sampleRate / source.sampleRate) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
    }

    /// Waits until everything fed so far has been recognized and matched (the end of an audio file).
    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await reading.value
    }

    func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        reading.cancel()
    }
}
