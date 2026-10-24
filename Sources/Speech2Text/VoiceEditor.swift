import DictationSpeech
import Foundation

/// A hands-free edit of the text dictated so far. See DESIGN.md, "말로 고치기".
enum VoiceCommand: Equatable {
    case deleteLastSentence, deleteLastWord, clearAll, undo
    case replace(String, String)

    /// Fixed phrases compared without spaces, punctuation, or a polite ending, because recognition spaces Korean
    /// freely ("지워 줘", "지워줘").
    private static let phrases: [(VoiceCommand, [String])] = [
        (.deleteLastSentence, ["지워", "그거지워", "방금거지워", "방금문장지워", "마지막문장지워", "문장지워",
                               "deletethat", "scratchthat", "deletelastsentence"]),
        (.deleteLastWord, ["단어지워", "한단어지워", "마지막단어지워", "deletelastword", "deleteword"]),
        (.clearAll, ["다지워", "전부지워", "모두지워", "전체지워", "clearall", "deleteall", "deleteeverything"]),
        (.undo, ["되돌려", "되돌리기", "실행취소", "원래대로", "undo", "undothat"]),
    ]
    private static let politeEndings = ["주세요", "줘요", "줘"]
    /// Words the recognizer gets as context so the commands are heard as written.
    static let terms = ["지워", "되돌려", "바꿔"]

    static func normalized(_ text: String) -> String {
        var compact = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        for ending in politeEndings where compact.hasSuffix(ending) && compact.count > ending.count {
            compact.removeLast(ending.count)
            break
        }
        return compact
    }

    static func parse(_ utterance: String) -> VoiceCommand? {
        let compact = normalized(utterance)
        guard !compact.isEmpty else { return nil }
        if let match = phrases.first(where: { $0.1.contains(compact) }) { return match.0 }
        return replacement(in: utterance)
    }

    /// True while a provisional utterance could still turn into a fixed command, so it is not typed yet.
    static func mightBecomeCommand(_ utterance: String) -> Bool {
        let compact = normalized(utterance)
        return !compact.isEmpty && phrases.contains { $0.1.contains { $0.hasPrefix(compact) } }
    }

    private static let replacePatterns = [
        #"^\s*(.{1,30}?)\s*(?:을|를)\s+(.{1,30}?)\s*(?:으로|로)\s*바꿔\s*(?:주세요|줘요|줘)?\s*[.!?。]*\s*$"#,
        #"^\s*(?:replace|change)\s+(.{1,30}?)\s+(?:with|to)\s+(.{1,30}?)\s*[.!?]*\s*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func replacement(in utterance: String) -> VoiceCommand? {
        let range = NSRange(utterance.startIndex..., in: utterance)
        for pattern in replacePatterns {
            guard let match = pattern.firstMatch(in: utterance, range: range),
                  let old = Range(match.range(at: 1), in: utterance), let new = Range(match.range(at: 2), in: utterance)
            else { continue }
            let quotes = CharacterSet(charactersIn: "\"'“”‘’ ")
            return .replace(utterance[old].trimmingCharacters(in: quotes), utterance[new].trimmingCharacters(in: quotes))
        }
        return nil
    }
}

/// Turns spoken turns into the text to type. A command only counts when Soniox finalized it as a turn of its own,
/// that is, said after a pause and followed by one; the same words inside a sentence are ordinary text.
struct VoiceEditor {
    /// The silence Soniox's word times must show before a command. Soniox sometimes closes a turn at a short
    /// hesitation, so a turn of its own alone is not proof that the speaker stopped. See DESIGN.md, "말로 고치기".
    static let commandPauseMs = 800
    enum Outcome: Equatable {
        case applied(VoiceCommand)
        case nothingToChange(VoiceCommand)
        case notFound(String)
    }

    struct Result: Equatable {
        var text = ""
        var outcomes: [Outcome] = []
    }

    static func apply(_ turns: [SpokenTurn], commandsEnabled: Bool) -> Result {
        var result = Result()
        var undo: [String] = []
        for (index, turn) in turns.enumerated() {
            let spoken = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { continue }
            if commandsEnabled, (turn.pauseBeforeMs ?? .max) >= commandPauseMs {
                if let command = VoiceCommand.parse(spoken) {
                    // Held back until Soniox finalizes it; once final it edits instead of being typed.
                    if turn.isFinal { result.outcomes.append(perform(command, on: &result.text, undo: &undo)) }
                    continue
                }
                if !turn.isFinal, index == turns.count - 1, VoiceCommand.mightBecomeCommand(spoken) { continue }
            }
            result.text = result.text.isEmpty ? spoken : result.text + " " + spoken
        }
        return result
    }

    private static func perform(_ command: VoiceCommand, on text: inout String, undo: inout [String]) -> Outcome {
        let before = text
        switch command {
        case .undo:
            guard let previous = undo.popLast() else { return .nothingToChange(command) }
            text = previous
            return .applied(command)
        case .deleteLastSentence: text = removingLastSentence(text)
        case .deleteLastWord: text = removingLastWord(text)
        case .clearAll: text = ""
        case .replace(let old, let new):
            guard let range = text.range(of: old, options: [.caseInsensitive, .backwards]) else { return .notFound(old) }
            text.replaceSubrange(range, with: new)
        }
        guard text != before else { return .nothingToChange(command) }
        undo.append(before)
        return .applied(command)
    }

    private static let sentenceEnds: Set<Character> = [".", "?", "!", "。", "…"]

    static func removingLastSentence(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespaces)
        while let last = body.last, sentenceEnds.contains(last) { body.removeLast() }
        guard let end = body.lastIndex(where: { sentenceEnds.contains($0) }) else { return "" }
        return String(body[...end])
    }

    static func removingLastWord(_ text: String) -> String {
        let body = text.trimmingCharacters(in: .whitespaces)
        guard let space = body.lastIndex(where: \.isWhitespace) else { return "" }
        return String(body[..<space]).trimmingCharacters(in: .whitespaces)
    }
}
