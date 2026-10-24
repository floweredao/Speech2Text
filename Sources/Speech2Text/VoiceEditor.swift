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

/// Turns spoken turns into the text to type. A command only counts right after the trigger word ("<trigger> 지워"),
/// in the same turn or, when the speaker paused after the trigger word, as the next turn; the same words without it
/// are ordinary text. Words after the trigger word that are no command are typed as said. See DESIGN.md, "말로 고치기".
struct VoiceEditor {
    enum Outcome: Equatable {
        case applied(VoiceCommand)
        case nothingToChange(VoiceCommand)
        case notFound(String)
    }

    struct Result: Equatable {
        var text = ""
        var outcomes: [Outcome] = []
    }

    static func apply(_ turns: [SpokenTurn], commandsEnabled: Bool, trigger: SpokenPhrase) -> Result {
        var result = Result()
        var undo: [String] = []
        var index = turns.startIndex
        while index < turns.endIndex {
            let turn = turns[index]
            index += 1
            let spoken = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { continue }
            guard commandsEnabled, let (before, after) = trigger.split(spoken) else {
                append(heldBack(spoken, isLast: index == turns.endIndex && !turn.isFinal, trigger: commandsEnabled ? trigger : nil),
                       to: &result.text)
                continue
            }
            var said = spoken, command = after, isFinal = turn.isFinal
            if after.isEmpty {
                // The speaker paused after the trigger word; the command is the next turn, still to come when none.
                guard index < turns.endIndex else {
                    append(before, to: &result.text)
                    continue
                }
                command = turns[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
                said += " " + command
                isFinal = turns[index].isFinal
                index += 1
            }
            // Nothing after the trigger word is typed before Soniox finalizes it: it may still become a command.
            guard isFinal else {
                append(before, to: &result.text)
                continue
            }
            if let parsed = VoiceCommand.parse(command) {
                append(before, to: &result.text)
                result.outcomes.append(perform(parsed, on: &result.text, undo: &undo))
            } else {
                append(said, to: &result.text)
            }
        }
        return result
    }

    /// A provisional last turn ending in the start of the trigger word waits for the rest before it is typed.
    private static func heldBack(_ spoken: String, isLast: Bool, trigger: SpokenPhrase?) -> String {
        guard isLast, let trigger, let start = trigger.partialSuffixStart(spoken) else { return spoken }
        return String(spoken[..<start]).trimmingCharacters(in: .whitespaces)
    }

    private static func append(_ words: String, to text: inout String) {
        guard !words.isEmpty else { return }
        text = text.isEmpty ? words : text + " " + words
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
