import Foundation
import os
import Security

/// How a spoken edit ("지워", "되돌려", "A를 B로 바꿔", "엔터 보내기") is told apart from dictated words.
/// See DESIGN.md, "말로 고치기".
enum CommandJudgeMode: String, CaseIterable, Sendable {
    /// Jev decides from the words before; unsure, failed or slow answers type the words.
    case jev
    /// Everything is typed.
    case off

    /// The stored choice. The trigger word it once offered is gone, so that choice reads as Jev; settings written
    /// before any choice existed keep their voice-editing switch.
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        if let stored = defaults.string(forKey: "commandJudge") { return stored == Self.off.rawValue ? .off : .jev }
        return defaults.object(forKey: "voiceEditingEnabled") as? Bool == false ? .off : .jev
    }
}

/// What a spoken command may do. Jev judges whether the words are a command; each action can be turned off, and an
/// action that is off is typed as said and never sent to Jev. See DESIGN.md, "말로 고치기".
enum VoiceAction: String, CaseIterable, Sendable {
    /// The last sentence, word or letter, or a part named in the command ("A 지워").
    case delete
    case clearAll
    /// "A를 B로 바꿔", "A 아니고 B", spacing and case.
    case replace
    case undo
    /// A punctuation mark said by name.
    case mark
    /// The spoken Return at the end of a dictation (`SpokenEnter`).
    case enter

    /// The actions `VoiceEditor` performs on the text; Return is pressed by `AppModel`.
    static let edits = Set(allCases).subtracting([.enter])

    /// Actions turned off in Settings are stored, so an action added later starts on.
    static func load(_ defaults: UserDefaults = .standard) -> Set<Self> {
        let off = Set((defaults.stringArray(forKey: "voiceActionsOff") ?? []).compactMap(Self.init))
        return edits.subtracting(off)
    }

    static func store(_ on: Set<Self>, _ defaults: UserDefaults = .standard) {
        let off = edits.subtracting(on).map(\.rawValue).sorted()
        defaults.set(off.isEmpty ? nil : off, forKey: "voiceActionsOff")
    }
}

extension VoiceCommand {
    var action: VoiceAction {
        switch self {
        case .deleteLastSentence, .deleteLastWord, .deleteLastCharacter, .delete: .delete
        case .clearAll: .clearAll
        case .replace: .replace
        case .undo: .undo
        case .mark: .mark
        }
    }
}

enum CommandVerdict: Equatable, Sendable { case command, text }

/// A finished speech chunk that ends in a command, waiting for Jev.
struct CommandQuestion: Equatable, Sendable {
    /// The same chunk asks once, however often the dictation is recomputed.
    let key: String
    let textBefore: String
    let utterance: String
    let joint: CommandCandidate.Joint
    let effect: String
}

/// The command at the end of a chunk: the whole chunk, or the clause after its last sentence mark or comma.
struct CommandCandidate: Equatable {
    enum Joint: String, Sendable {
        case ownChunk = "own chunk"
        case afterSentence = "after a sentence end"
        case afterComma = "after a comma"
        case afterWord = "right after a word, in the same sentence"
    }

    let before: String
    let tail: String
    let command: VoiceCommand
    let joint: Joint

    private static let clauseEnds: Set<Character> = [".", "!", "?", "。", ",", "，"]

    init?(_ chunk: String) {
        let text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = Substring(text)
        while let last = body.last, last.isWhitespace || Self.clauseEnds.contains(last) { body.removeLast() }
        // The last clause goes first: "A를 B로 바꿔" read over the whole chunk would take earlier sentences into A.
        guard let cut = body.lastIndex(where: Self.clauseEnds.contains),
              case let tail = text[text.index(after: cut)...].trimmingCharacters(in: .whitespacesAndNewlines),
              let command = VoiceCommand.parse(tail) else {
            if let whole = VoiceCommand.parse(text) {
                (before, tail, command, joint) = ("", text, whole, .ownChunk)
                return
            }
            // A mark name is often said straight after the sentence it ends ("내일 와 물음표 찍어 줘").
            let words = body.split(whereSeparator: \.isWhitespace)
            for count in 1...min(3, max(words.count - 1, 1)) where words.count > count {
                let tail = words.suffix(count).joined(separator: " ")
                guard let parsed = VoiceCommand.parse(tail), case .mark = parsed else { continue }
                (before, self.tail, command, joint) = (words.dropLast(count).joined(separator: " "), tail, parsed, .afterWord)
                return
            }
            return nil
        }
        var before = String(text[...cut])
        while let last = before.last, last.isWhitespace || last == "," || last == "，" { before.removeLast() }
        (self.before, self.tail, self.command) = (before, tail, command)
        joint = body[cut] == "," || body[cut] == "，" ? .afterComma : .afterSentence
    }

    var effect: String {
        switch command {
        case .deleteLastSentence: "delete the last sentence of the dictated text"
        case .deleteLastWord: "delete the last word of the dictated text"
        case .deleteLastCharacter: "delete the last letter of the dictated text"
        case .clearAll: "delete all of the dictated text"
        case .undo: "undo the previous voice edit"
        case .replace(let old, let new): "replace the last \"\(old)\" in the dictated text with \"\(new)\""
        case .delete(let old): "delete the last \"\(old)\" from the dictated text"
        case .mark(let mark):
            "put the punctuation mark \"\(mark == PunctuationStyle.spokenComma ? "," : String(mark))\" at the end of the dictated text"
        }
    }
}

/// One answer from Jev, kept for diagnostics (`--print-turns`).
struct JudgeAnswer: Equatable, Sendable {
    let verdict: CommandVerdict
    let commandProbability: Double?
    let milliseconds: Int
    let inputTokens: Int
    /// Why the words were typed without a real answer: missing key, HTTP error, timeout.
    let failure: String?
}

/// Asks TypeSafe Jev (System One, a choice question) whether a chunk is an edit or dictated words.
/// Only the chunk and up to 400 characters before it are sent. Anything but a confident COMMAND types the words.
struct JevJudge: Sendable {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-1.14.0"
    /// Calibrated on written cases and say-generated speech through Soniox (lane s2t-jev-command): intended edits
    /// mostly scored 0.76-0.99, dictated requests mostly 0.14-0.67.
    static let commandThreshold = 0.7
    static let timeout: Duration = .milliseconds(1500)
    static let contextLimit = 400

    var timeout = JevJudge.timeout
    var send: Send = { try await URLSession.shared.data(for: $0) }

    static let guide = [
        "A person dictates by voice into another app: chat messages, documents, and often instructions to an AI coding agent or a colleague. Speech is mostly Korean, sometimes English.",
        "The dictation app also takes editing commands, said in many ways (any object word, verb form, polite ending or spacing): deleting the last sentence (지워, 방금 거 삭제해 줘, 앞 문장 날려, scratch that), the last word (한 단어 지워) or letter (한 글자 지워), everything (다 지워, 전부 날려, clear all), undoing the last edit (되돌려, 방금 거 취소, 원래대로, undo), fixing a word ('A를 B로 바꿔/고쳐/수정해', 'A 대신 B로', 'replace A with B', 'A 대문자로 바꿔', 'A B 띄어 써', 'A B 붙여 써'), the speaker saying the right word again ('A 아니고 B', 'A 말고 B', 'A가 아니라 B', 'A, I mean B'), removing a word ('A 지워/빼', 'A라는 단어 삭제해', 'delete A'), 엔터 보내기 (press Return to send), and punctuation marks said by name: 물음표 / 느낌표 / 마침표 / 쉼표 / 콜론 / 물결표 / 말줄임표 / question mark / comma (put that mark at the end of the dictated text).",
        "A mark name is TEXT when the sentence talks about the mark or uses the word for its meaning: '물음표가 뜨어요' is not asked, but '드디어 마침표' (finally an end), '인생의 물음표' (a question in life), '저 줄에 마침표' (a mark on that line, said to the reader) are TEXT. '내일 오나요 물음표' or '좋아요 느낌표' dictating the mark for the speaker's own sentence is COMMAND.",
        "The same words are very common inside the dictated message itself, above all in requests to someone else: '그 파일 지워', '버튼 색을 파란색으로 바꿔', '테스트 다 지워', '그 커밋 되돌려'. Those are TEXT.",
        "Key test: does the utterance act on the speaker's own dictated words, or on something in the world that the message talks about? When `text_before` points the reader at a thing (a file, branch, cache, script, calendar entry, screen, message; '~ 있잖아', '~ 말이야', 'X is broken', 'X가 보였어', 'X 때문에') and the utterance says what to do with that thing, it is an instruction to the reader: TEXT, even when said as a separate chunk and even when the word to replace appears in `text_before`.",
        "COMMAND when the utterance fixes the dictation itself: the text before is a plain statement the speaker just made and the utterance corrects or removes it (a misheard or wrong word, a sentence to take back, hesitation or filler to clear).",
        "`joint` tells how the utterance was said: as its own chunk after a pause, right after a sentence end, or after a comma in the same sentence. After a comma it usually finishes that sentence ('그 파일은, 지워'), which is TEXT unless the words before it are clearly abandoned.",
        "When unsure, choose TEXT: typing the words is harmless, a wrong edit destroys text.",
    ].joined(separator: "\n")

    private struct Body: Encodable {
        struct State: Encodable {
            let guide: String
            let text_before: String
            let utterance: String
            let joint: String
            let effect: String
        }
        struct Question: Encodable {
            let type = "choice"
            let instructions = "`text_before` is what has been dictated so far (most recent last). `utterance` was just said. `effect` is what the dictation app would do if it is a command. Apply `guide`: is `utterance` an editing command to the dictation app, or part of the dictated text?"
            let criteria = [
                "COMMAND": "An edit aimed at the dictated text itself; the app should perform `effect` and not type the words.",
                "TEXT": "Part of the message being dictated; the app should type the words.",
            ]
        }
        let model: String
        let state: State
        let questions: [String: Question]
    }

    private struct Response: Decodable {
        struct Answer: Decodable {
            let choice: String?
            let probabilities: [String: Double]?
        }
        struct Usage: Decodable { let input_tokens: Int? }
        let answers: [String: Answer]?
        let usage: Usage?
    }

    static func request(for question: CommandQuestion, key: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let state = Body.State(guide: guide, text_before: String(question.textBefore.suffix(contextLimit)),
                               utterance: question.utterance, joint: question.joint.rawValue, effect: question.effect)
        request.httpBody = try JSONEncoder().encode(Body(model: model, state: state, questions: ["q": Body.Question()]))
        return request
    }

    func judge(_ question: CommandQuestion, key: String?) async -> JudgeAnswer {
        let started = ContinuousClock.now
        func answer(_ verdict: CommandVerdict, _ probability: Double? = nil, tokens: Int = 0, failure: String? = nil) -> JudgeAnswer {
            let elapsed = started.duration(to: .now)
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            if let failure { Self.log.notice("Jev not used: \(failure, privacy: .public)") }
            else { Self.log.notice("Jev \(verdict == .command ? "COMMAND" : "TEXT", privacy: .public) p=\(probability ?? -1, privacy: .public) \(question.joint.rawValue, privacy: .public)") }
            return JudgeAnswer(verdict: verdict, commandProbability: probability, milliseconds: ms, inputTokens: tokens, failure: failure)
        }
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return answer(.text, failure: "no key")
        }
        do {
            let request = try Self.request(for: question, key: key)
            let send = send, timeout = timeout
            let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask { try await send(request) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return answer(.text, failure: "HTTP \(status)") }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let probability = decoded.answers?["q"]?.probabilities?["COMMAND"]
            let tokens = decoded.usage?.input_tokens ?? 0
            guard let probability else { return answer(.text, tokens: tokens, failure: "no answer") }
            return answer(probability >= Self.commandThreshold ? .command : .text, probability, tokens: tokens)
        } catch let error as URLError where error.code == .timedOut {
            return answer(.text, failure: "timeout")
        } catch {
            return answer(.text, failure: "\(type(of: error))")
        }
    }

    private static let log = Logger(subsystem: "local.speech2text.app", category: "command-judge")
}

/// The Jev API key, kept in this app's Keychain next to the Soniox key.
enum JevKeychain {
    private static let service = "com.speech2text.credentials"
    private static let account = "jev"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    static func load() -> String? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) -> Bool {
        let update = [kSecValueData as String: Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var attributes = query.merging(update) { _, new in new }
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// A service whose API key this app keeps in its own Keychain item. See DESIGN.md, "키 관리".
enum ServiceKey: String, CaseIterable, Sendable {
    case soniox, jev

    /// Where a person gets a key of their own.
    var consoleURL: URL {
        switch self {
        case .soniox: URL(string: "https://console.soniox.com")!
        case .jev: URL(string: "https://console.typesafe.ai")!
        }
    }

    /// Lists the service's models: needs a valid key, transcribes or judges nothing, and costs nothing.
    var checkURL: URL {
        switch self {
        case .soniox: URL(string: "https://api.soniox.com/v1/models")!
        case .jev: URL(string: "https://api.typesafe.ai/v1/models")!
        }
    }

    /// Shows which key is stored without showing the key: its last four characters, only when it is long enough
    /// that they give little away.
    static func masked(_ key: String) -> String {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.count >= 12 ? "••••" + key.suffix(4) : "••••"
    }
}

enum KeyCheck: Equatable, Sendable {
    case valid
    /// The service turned the key down (HTTP 401 or 403).
    case refused
    /// No answer about the key: offline, timeout, or another HTTP status.
    case failed(String)
}

/// Asks a service whether a key works, with a request that uses no credit.
struct KeyChecker: Sendable {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    var send: Send = { try await URLSession.shared.data(for: $0) }

    static func request(_ service: ServiceKey, key: String) -> URLRequest {
        var request = URLRequest(url: service.checkURL, timeoutInterval: 10)
        request.setValue("Bearer \(key.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        return request
    }

    func check(_ service: ServiceKey, key: String) async -> KeyCheck {
        do {
            let (_, response) = try await send(Self.request(service, key: key))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: return .valid
            case 401, 403: return .refused
            default: return .failed("HTTP \(status)")
            }
        } catch let error as URLError {
            return .failed(error.code == .timedOut ? "timeout" : "URLError \(error.code.rawValue)")
        } catch {
            return .failed("\(type(of: error))")
        }
    }
}
