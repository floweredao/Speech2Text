internal import CSherpaOnnx
import Foundation
import os

/// How readily the wake phrase counts as heard. Higher catches softer or accented speech and false-triggers more.
public enum WakeSensitivity: String, CaseIterable, Sendable {
    case low, standard, high

    /// sherpa-onnx's keyword threshold: the averaged token probability the phrase must reach.
    var threshold: Float {
        switch self {
        case .low: 0.35
        case .standard: 0.25
        case .high: 0.15
        }
    }
}

/// Splits a wake phrase into the keyword model's word pieces. The model's tokenizer is a sentencepiece unigram
/// model, so the right split is the one whose pieces have the highest total log-probability (Viterbi search);
/// merging the best-scoring neighbours greedily gives different pieces, which the model then never emits.
public struct WakePhraseTokenizer: Sendable {
    private let scores: [String: Float]
    private let longestPiece: Int

    init(scores: [String: Float]) {
        self.scores = scores
        longestPiece = scores.keys.map(\.count).max() ?? 1
    }

    /// Reads the normal pieces and their scores from a sentencepiece `ModelProto` (field 1, repeated pieces).
    public init(sentencepieceModel url: URL) throws {
        var reader = ProtoReader(try Data(contentsOf: url))
        var scores: [String: Float] = [:]
        while let field = try reader.next() {
            guard field.number == 1, case .bytes(let bytes) = field.value else { continue }
            var piece = ProtoReader(bytes)
            var text: String?, score: Float = 0, type: UInt64 = 1
            while let part = try piece.next() {
                switch (part.number, part.value) {
                case (1, .bytes(let raw)): text = String(decoding: raw, as: UTF8.self)
                case (2, .fixed32(let bits)): score = Float(bitPattern: bits)
                case (3, .varint(let value)): type = value
                default: break
                }
            }
            if let text, type == 1 { scores[text] = score }
        }
        guard !scores.isEmpty else { throw AppError.invalidResponse("Wake word vocabulary is empty") }
        self.init(scores: scores)
    }

    /// The pieces for `phrase`, or nil when it has no letters or uses characters the English model cannot spell.
    public func pieces(for phrase: String) -> [String]? {
        let words = phrase.uppercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        var result: [String] = []
        for word in words {
            guard word.allSatisfy({ ("A"..."Z").contains($0) || $0 == "'" }), let pieces = split("▁" + word) else {
                return nil
            }
            result += pieces
        }
        return result
    }

    private func split(_ word: String) -> [String]? {
        let characters = Array(word)
        var best = [Float](repeating: -.infinity, count: characters.count + 1)
        var start = [Int](repeating: -1, count: characters.count + 1)
        best[0] = 0
        for end in 1...characters.count {
            for begin in max(0, end - longestPiece)..<end where best[begin] > -.infinity {
                guard let score = scores[String(characters[begin..<end])], best[begin] + score > best[end] else { continue }
                best[end] = best[begin] + score
                start[end] = begin
            }
        }
        guard best[characters.count] > -.infinity else { return nil }
        var pieces: [String] = []
        var end = characters.count
        while end > 0 {
            pieces.insert(String(characters[start[end]..<end]), at: 0)
            end = start[end]
        }
        return pieces
    }
}

private struct ProtoReader {
    enum Value { case varint(UInt64), fixed32(UInt32), fixed64, bytes(Data) }
    private let data: Data
    private var index: Data.Index
    init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    mutating func next() throws -> (number: UInt64, value: Value)? {
        guard index < data.endIndex else { return nil }
        let key = try varint()
        switch key & 7 {
        case 0: return (key >> 3, .varint(try varint()))
        case 1: try skip(8); return (key >> 3, .fixed64)
        case 2:
            let length = Int(try varint())
            let begin = index
            try skip(length)
            return (key >> 3, .bytes(data[begin..<index]))
        case 5:
            let begin = index
            try skip(4)
            let bits = data[begin..<index].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return (key >> 3, .fixed32(bits))
        default: throw AppError.invalidResponse("Unreadable wake word vocabulary")
        }
    }

    private mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0, shift: UInt64 = 0
        while true {
            guard index < data.endIndex, shift < 64 else { throw AppError.invalidResponse("Unreadable wake word vocabulary") }
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    private mutating func skip(_ count: Int) throws {
        guard count >= 0, data.distance(from: index, to: data.endIndex) >= count else {
            throw AppError.invalidResponse("Unreadable wake word vocabulary")
        }
        index += count
    }
}

/// One sherpa-onnx keyword spotter and its stream. Used by one task at a time: the listener creates it, feeds it
/// and drops it on the same detached task.
final class WakeSpotter: @unchecked Sendable {
    /// onnxruntime keeps one process-wide logging manager, and two spotters set up or torn down at the same moment can
    /// fail with "Only one instance of LoggingManager ... can exist" (seen once in the test suite). A listener restarts
    /// while the phrase is typed, so loading and freeing take turns.
    private static let lifecycle = NSLock()
    private let spotter: OpaquePointer
    private let stream: OpaquePointer

    init(model: URL, pieces: [String], sensitivity: WakeSensitivity) throws {
        let strings = ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"].map {
            strdup(model.appendingPathComponent($0).path)
        } + [strdup("cpu"), strdup(pieces.joined(separator: " "))]
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxKeywordSpotterConfig()
        config.feat_config = SherpaOnnxFeatureConfig(sample_rate: 16_000, feature_dim: 80)
        config.model_config.transducer.encoder = UnsafePointer(strings[0])
        config.model_config.transducer.decoder = UnsafePointer(strings[1])
        config.model_config.transducer.joiner = UnsafePointer(strings[2])
        config.model_config.tokens = UnsafePointer(strings[3])
        config.model_config.num_threads = 1
        config.model_config.provider = UnsafePointer(strings[4])
        config.max_active_paths = 4
        config.num_trailing_blanks = 1
        config.keywords_score = 1
        config.keywords_threshold = sensitivity.threshold
        config.keywords_buf = UnsafePointer(strings[5])
        config.keywords_buf_size = Int32(strlen(strings[5]!))
        let created: (OpaquePointer, OpaquePointer?)? = Self.lifecycle.withLock {
            guard let spotter = SherpaOnnxCreateKeywordSpotter(&config) else { return nil }
            guard let stream = SherpaOnnxCreateKeywordStream(spotter) else {
                SherpaOnnxDestroyKeywordSpotter(spotter)
                return (spotter, nil)
            }
            return (spotter, stream)
        }
        guard let created else { throw AppError.invalidResponse("Wake word model could not load") }
        guard let stream = created.1 else { throw AppError.invalidResponse("Wake word stream could not start") }
        spotter = created.0
        self.stream = stream
    }

    deinit {
        Self.lifecycle.withLock {
            SherpaOnnxDestroyOnlineStream(stream)
            SherpaOnnxDestroyKeywordSpotter(spotter)
        }
    }

    /// Feeds 16 kHz mono 16-bit little-endian audio; true when the phrase ended inside it.
    func accept(pcm: Data) -> Bool {
        let samples = pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
        }
        samples.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, $0.baseAddress, Int32($0.count)) }
        var heard = false
        while SherpaOnnxIsKeywordStreamReady(spotter, stream) != 0 {
            SherpaOnnxDecodeKeywordStream(spotter, stream)
            guard let result = SherpaOnnxGetKeywordResult(spotter, stream) else { continue }
            if let keyword = result.pointee.keyword, keyword.pointee != 0 {
                heard = true
                SherpaOnnxResetKeywordStream(spotter, stream)
            }
            SherpaOnnxDestroyKeywordResult(result)
        }
        return heard
    }
}

/// Listens on the microphone for the wake phrase, entirely on this Mac: audio goes to the local keyword model only
/// and is never stored or sent. The microphone stays open (and macOS shows its indicator) while listening.
@MainActor public final class WakeWordListener {
    private static let log = Logger(subsystem: "local.speech2text.app", category: "wake-word")
    private let model: URL
    private let captureFactory: @MainActor (String?) -> any AudioCapturing
    private var capture: (any AudioCapturing)?
    private var task: Task<Void, Never>?
    private var generation = 0
    /// Called on the main actor each time the phrase is heard; the listener keeps listening until stopped.
    public var onWake: (@MainActor () -> Void)?
    /// Called when listening stops by itself, with a message for the user.
    public var onFailure: (@MainActor (String) -> Void)?
    public private(set) var isListening = false
    public let tokenizer: WakePhraseTokenizer

    /// `model` holds encoder.onnx, decoder.onnx, joiner.onnx, tokens.txt and bpe.model.
    public convenience init(model: URL) throws {
        try self.init(model: model, captureFactory: { HALAudioCapture(deviceUID: $0) })
    }

    /// Diagnostic: listens to an audio file instead of the microphone, as fast as the model decodes it.
    public convenience init(model: URL, audioFile: URL) throws {
        try self.init(model: model, captureFactory: { _ in
            FileAudioCapture(url: audioFile, maximumSeconds: 3_600, realTime: false)
        })
    }

    init(model: URL, captureFactory: @escaping @MainActor (String?) -> any AudioCapturing) throws {
        self.model = model
        self.captureFactory = captureFactory
        tokenizer = try WakePhraseTokenizer(sentencepieceModel: model.appendingPathComponent("bpe.model"))
    }

    /// Starts listening for `pieces` (from `tokenizer`), replacing any earlier listening.
    public func start(pieces: [String], sensitivity: WakeSensitivity, deviceUID: String?) {
        stop()
        generation += 1
        let epoch = generation
        let capture = captureFactory(deviceUID)
        self.capture = capture
        isListening = true
        let model = model
        task = Task { [weak self] in
            do {
                let spotter = try await Task.detached(priority: .utility) {
                    try WakeSpotter(model: model, pieces: pieces, sensitivity: sensitivity)
                }.value
                try Task.checkCancellation()
                let chunks = try await capture.start(format: .pcm16Mono16k)
                Self.log.notice("listening")
                try await Task.detached(priority: .utility) {
                    for try await chunk in chunks where spotter.accept(pcm: chunk) {
                        await MainActor.run { self?.heard(epoch) }
                    }
                }.value
                try Task.checkCancellation()
                self?.ended(epoch, message: String(localized: "마이크가 끊겨 호출어를 듣지 않고 있어요."))
            } catch {
                guard !Task.isCancelled else { return }
                Self.log.error("stopped: \(String(describing: error), privacy: .public)")
                self?.ended(epoch, message: Self.message(for: error))
            }
        }
    }

    public func stop() {
        generation += 1
        task?.cancel()
        task = nil
        isListening = false
        if let capture {
            self.capture = nil
            Task { await capture.stop() }
        }
    }

    private func heard(_ epoch: Int) {
        guard epoch == generation else { return }
        Self.log.notice("wake phrase heard")
        onWake?()
    }

    private func ended(_ epoch: Int, message: String) {
        guard epoch == generation else { return }
        stop()
        onFailure?(message)
    }

    private static func message(for error: Error) -> String {
        switch error as? AppError {
        case .permissionDenied: String(localized: "마이크 권한이 없어 호출어를 들을 수 없어요.")
        case .inputDeviceUnavailable: String(localized: "고른 마이크를 찾지 못해 호출어를 듣지 않고 있어요.")
        default: String(localized: "마이크를 열지 못해 호출어를 듣지 않고 있어요.")
        }
    }
}
