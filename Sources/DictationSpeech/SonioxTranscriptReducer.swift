import Foundation

struct SonioxTranscriptReducer: Sendable {
    private var committed = ""
    private var committedSpans: [TimedText] = []
    private var turn = 0
    private var revision = 0
    private var ended = false
    private var lastText = ""
    /// With translation on, only translated tokens make up the text; otherwise translated tokens never do.
    private let translating: Bool
    init(translating: Bool = false) { self.translating = translating }
    mutating func reduce(_ data: Data) throws -> [TranscriptEvent] {
        struct Token: Decodable {
            let text: String; let is_final: Bool; let start_ms: Int?; let confidence: Double?; let translation_status: String?
        }
        struct Frame: Decodable { let tokens: [Token]?; let finished: Bool?; let error_code: Int?; let error_message: String? }
        let frame: Frame
        do { frame = try JSONDecoder().decode(Frame.self, from: data) }
        catch { throw AppError.invalidResponse("Soniox schema") }
        guard frame.error_code == nil, frame.error_message == nil else {
            throw AppError.provider(code: frame.error_code, message: frame.error_message ?? String(localized: "음성 인식 요청이 거절됐어요."))
        }
        guard !ended else { return [] }
        var events: [TranscriptEvent] = []
        var provisional = ""
        var provisionalSpans: [TimedText] = []
        func update(_ text: String, final: Bool, spans: [TimedText]) -> TranscriptEvent {
            revision += 1
            return .update(.init(turnID: "soniox-\(turn)", revision: revision, text: text, isFinal: final, spans: spans))
        }
        for token in frame.tokens ?? [] {
            if token.text == "<end>" || token.text == "<fin>" {
                guard token.is_final else { continue }
                if !committed.isEmpty {
                    events.append(update(committed, final: true, spans: committedSpans)); turn += 1; revision = 0
                    lastText = ""
                }
                // Without final text the turn goes on, and provisional text it showed must still be cleared.
                committed = ""; provisional = ""; committedSpans = []; provisionalSpans = []
            } else if (token.translation_status == "translation") != translating {
                continue
            } else if token.is_final {
                committed += token.text
                committedSpans.append(TimedText(text: token.text, startMs: token.start_ms, confidence: token.confidence))
            } else {
                provisional += token.text
                provisionalSpans.append(TimedText(text: token.text, startMs: token.start_ms, confidence: token.confidence))
            }
        }
        if frame.finished == true {
            if !committed.isEmpty { events.append(update(committed, final: true, spans: committedSpans)) }
            ended = true; events.append(.finished)
        } else if frame.tokens != nil && committed + provisional != lastText {
            lastText = committed + provisional
            events.append(update(lastText, final: false, spans: committedSpans + provisionalSpans))
        }
        return events
    }
}
