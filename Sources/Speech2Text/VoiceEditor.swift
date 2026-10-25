import DictationSpeech
import Foundation

/// A hands-free edit of the text dictated so far. See DESIGN.md, "말로 고치기".
enum VoiceCommand: Equatable {
    case deleteLastSentence, deleteLastWord, clearAll, undo
    case replace(String, String)
    /// "A 지워" / "delete A": removes the last A in the dictated text.
    case delete(String)
    /// A punctuation mark said by name ("물음표", "question mark"), put at the end of the dictated text.
    case mark(Character)

    /// Fixed phrases compared without spaces, punctuation, or a polite ending, because recognition spaces Korean
    /// freely ("지워 줘", "지워줘").
    private static let phrases: [(VoiceCommand, [String])] = [
        (.deleteLastSentence, ["지워", "그거지워", "방금거지워", "방금문장지워", "마지막문장지워", "문장지워",
                               "방금말한거지워", "방금말한것지워", "방금한말지워", "말한거지워", "방금말한문장지워",
                               "deletethat", "scratchthat", "deletelastsentence"]),
        (.deleteLastWord, ["단어지워", "한단어지워", "마지막단어지워", "deletelastword", "deleteword"]),
        (.clearAll, ["다지워", "전부지워", "모두지워", "전체지워", "clearall", "deleteall", "deleteeverything"]),
        (.undo, ["되돌려", "되돌리기", "실행취소", "원래대로", "undo", "undothat"]),
    ]
    private static let politeEndings = ["주세요", "줘요", "줘"]
    /// Mark names, compared like the phrases. A name with a particle ("물음표를") or inside a sentence is text.
    private static let markNames: [(Character, [String])] = [
        ("?", ["물음표", "questionmark"]),
        ("!", ["느낌표", "exclamationmark", "exclamationpoint"]),
        (".", ["마침표", "온점", "fullstop", "period"]),
        (PunctuationStyle.spokenComma, ["쉼표", "반점", "comma"]),
    ]
    /// "물음표 찍어", "쉼표 넣어 줘".
    private static let markVerbs = ["", "찍어", "붙여", "넣어"]
    /// Words the recognizer gets as context so the commands are heard as written.
    static let terms = ["지워", "되돌려", "바꿔", "물음표", "느낌표", "마침표", "쉼표", "괄호", "괄호 열고", "괄호 닫고"]

    /// The mark a word names ("물음표" -> "?"), so "물음표 지워" finds the "?" in the text.
    static func markNamed(_ word: String) -> Character? {
        let compact = normalized(word)
        return markNames.first { $0.1.contains(compact) }?.0
    }

    private static func target(_ word: Substring) -> String {
        let word = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ "))
        return markNamed(word).map(String.init) ?? word
    }

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
        for (mark, names) in markNames {
            if names.contains(where: { name in markVerbs.contains { name + $0 == compact } }) { return .mark(mark) }
        }
        return replacement(in: utterance) ?? deletion(in: utterance)
    }

    private static let deletePatterns = [
        #"^\s*(.{1,30}?)\s*(?:을|를|은|는|이|가)?\s*(?:지워|빼|삭제해|삭제|없애|떼)\s*(?:버려)?\s*(?:주세요|줘요|줘)?\s*[.!?。]*\s*$"#,
        #"^\s*(?:delete|remove|erase)\s+(.{1,30}?)\s*[.!?]*\s*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func deletion(in utterance: String) -> VoiceCommand? {
        let range = NSRange(utterance.startIndex..., in: utterance)
        for pattern in deletePatterns {
            guard let match = pattern.firstMatch(in: utterance, range: range),
                  let target = Range(match.range(at: 1), in: utterance) else { continue }
            let word = Self.target(utterance[target])
            return word.isEmpty ? nil : .delete(word)
        }
        return nil
    }

    private static let replacePatterns = [
        #"^\s*(.{1,30}?)\s*(?:을|를)\s*(.{1,30}?)\s*(?:으로|로|라고|이라고)\s*(?:바꿔|고쳐|수정해|변경해)\s*(?:주세요|줘요|줘)?\s*[.!?。]*\s*$"#,
        #"^\s*(?:replace|change)\s+(.{1,30}?)\s+(?:with|to)\s+(.{1,30}?)\s*[.!?]*\s*$"#,
        // Correcting by saying it again: "세 시 아니고 네 시", "아니 세 시 말고 네 시로", "세 시가 아니라 네 시야", "세 시 대신 네 시".
        #"^\s*(?:아니\s*[,，]?\s+)?(.{1,15}?)\s*(?:이|가)?\s*(?:아니고|아니라|말고|아니[,，]|아니(?=\s)|대신에|대신)\s*[,，]?\s*(.{1,15}?)\s*(?:으로|로|이야|이에요|예요|야|요)?\s*[.!?。]*\s*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func replacement(in utterance: String) -> VoiceCommand? {
        let range = NSRange(utterance.startIndex..., in: utterance)
        for (index, pattern) in replacePatterns.enumerated() {
            guard let match = pattern.firstMatch(in: utterance, range: range),
                  let oldRange = Range(match.range(at: 1), in: utterance),
                  let newRange = Range(match.range(at: 2), in: utterance)
            else { continue }
            let (old, new) = (Self.target(utterance[oldRange]), Self.target(utterance[newRange]))
            guard !old.isEmpty, !new.isEmpty else { continue }
            // A one-letter "A 아니고 B" is mostly a word Soniox split ("3. / 시가 아니라 4시"); it would cut into another word.
            if index == 2, old.count < 2, markNamed(old) == nil { continue }
            return .replace(old, new)
        }
        return nil
    }
}

/// Turns spoken turns into the text to type. With a trigger word a command only counts right after it ("<trigger> 지워"),
/// in the same turn or, when the speaker paused after the trigger word, as the next turn; the same words without it
/// are ordinary text. Words after the trigger word that are no command are typed as said. With Jev a finished turn
/// ending in a command waits for Jev's verdict. See DESIGN.md, "말로 고치기".
struct VoiceEditor {
    enum Gate: Equatable {
        case off
        case trigger(SpokenPhrase)
        /// Verdicts Jev gave so far, by `CommandQuestion.key`; `unanswered` settles turns not answered yet instead of
        /// waiting for them.
        case judged([String: CommandVerdict], unanswered: CommandVerdict? = nil)
    }

    enum Outcome: Equatable {
        case applied(VoiceCommand)
        case nothingToChange(VoiceCommand)
        case notFound(String)
    }

    struct Result: Equatable {
        var text = ""
        var outcomes: [Outcome] = []
        /// The turn waiting for Jev; it and every later turn are left out of `text` until it is answered.
        var question: CommandQuestion?
        /// `text` right after the last outcome; nil when no edit was asked for.
        var textAtLastEdit: String?
        /// Words were typed after the last edit, so a note about that edit would read as if it were about them.
        var saidMoreAfterEdit: Bool { textAtLastEdit.map { $0 != text } ?? false }
    }

    static func apply(_ turns: [SpokenTurn], commandsEnabled: Bool, trigger: SpokenPhrase) -> Result {
        apply(turns, gate: commandsEnabled ? .trigger(trigger) : .off)
    }

    static func apply(_ turns: [SpokenTurn], gate: Gate) -> Result {
        if case .judged(let verdicts, let unanswered) = gate { return judged(turns, verdicts: verdicts, unanswered: unanswered) }
        var commandsEnabled = false, trigger = SpokenPhrase("")
        if case .trigger(let phrase) = gate { (commandsEnabled, trigger) = (true, phrase) }
        var result = Result()
        var undo: [String] = []
        var index = turns.startIndex
        while index < turns.endIndex {
            let turn = turns[index]
            index += 1
            var spoken = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if commandsEnabled { spoken = brackets(spoken) }
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
                result.textAtLastEdit = result.text
            } else {
                append(said, to: &result.text)
            }
        }
        result.text = tidyBrackets(result.text)
        return result
    }

    private static let bracketWords: [(NSRegularExpression, String)] = [
        (#"[,，.。]?\s*(?:소?괄호\s*(?:를|을)?\s*(?:열고|열어서|열어|열기|시작하고|시작)|여는\s*괄호|open\s+(?:paren(?:thesis)?|bracket))\s*[,，.。]?"#, " ("),
        (#"[,，.。]?\s*(?:소?괄호\s*(?:를|을)?\s*(?:닫고|닫아서|닫아|닫기|끝)|닫는\s*괄호(?:를|을)?|close\s+(?:paren(?:thesis)?|bracket))\s*[,，]?"#, ") "),
    ].compactMap { pattern, mark in
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { ($0, mark) }
    }

    /// "괄호 열고 오후 괄호 닫고" -> "(오후)": brackets said by name inside a sentence, with the marks Soniox put around them.
    static func brackets(_ spoken: String) -> String {
        var text = spoken
        for (regex, mark) in bracketWords {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: mark)
        }
        return text == spoken ? spoken : tidyBrackets(text)
    }

    /// A bracket hugs the words inside it, also when they were said in turns of their own.
    static func tidyBrackets(_ text: String) -> String {
        guard text.contains("(") || text.contains(")") else { return text }
        return text.replacingOccurrences(of: #"\(\s+"#, with: "(", options: .regularExpression)
            .replacingOccurrences(of: #"[,，.。]?\s+\)"#, with: ")", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func questionKey(_ turn: SpokenTurn) -> String { "\(turn.pauseBeforeMs ?? -1)|\(turn.text)" }

    /// Only edits Jev may get wrong are asked. Nothing dictated yet, nothing to undo, or a word to replace that was
    /// never said makes the words text; "되돌려" right after an edit undoes it, so a wrong edit is always revertible.
    /// A mark name said as its own chunk is settled; one ending a sentence ("드디어 마침표") is asked.
    private static func settled(_ command: VoiceCommand, before: String, joint: CommandCandidate.Joint, canUndo: Bool,
                                afterEdit: Bool) -> CommandVerdict? {
        switch command {
        case .mark:
            if before.trimmingCharacters(in: .whitespaces).isEmpty { return .text }
            return joint == .ownChunk ? .command : nil
        case .undo: return canUndo ? (afterEdit ? .command : nil) : .text
        case .replace(let old, _) where VoiceEditor.lastRange(of: old, in: before) == nil: return .text
        case .delete(let old) where VoiceEditor.lastRange(of: old, in: before) == nil: return .text
        // "물음표 지워" names a mark the text holds; it is never part of a message, and "되돌려" brings it back.
        case .delete(let old) where old.count == 1 && VoiceEditor.markEnds.contains(old.first!): return .command
        default: return before.trimmingCharacters(in: .whitespaces).isEmpty ? .text : nil
        }
    }

    private static func judged(_ turns: [SpokenTurn], verdicts: [String: CommandVerdict], unanswered: CommandVerdict?) -> Result {
        var result = Result()
        var undo: [String] = []
        var afterEdit = false
        for turn in turns {
            let spoken = brackets(turn.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !spoken.isEmpty else { continue }
            guard let candidate = CommandCandidate(spoken) else {
                append(spoken, to: &result.text)
                afterEdit = false
                continue
            }
            // A command still being said never flashes into the field.
            guard turn.isFinal else {
                append(candidate.before, to: &result.text)
                continue
            }
            var before = result.text
            append(candidate.before, to: &before)
            let key = questionKey(turn)
            switch settled(candidate.command, before: before, joint: candidate.joint, canUndo: !undo.isEmpty,
                           afterEdit: afterEdit) ?? verdicts[key] ?? unanswered {
            case .command?:
                result.text = before
                let outcome = perform(candidate.command, on: &result.text, undo: &undo)
                result.outcomes.append(outcome)
                result.textAtLastEdit = result.text
                if case .applied = outcome { afterEdit = true }
            case .text?:
                append(spoken, to: &result.text)
                afterEdit = false
            case nil:
                result.text = before
                result.question = CommandQuestion(key: key, textBefore: before, utterance: candidate.tail,
                                                  joint: candidate.joint, effect: candidate.effect)
                result.text = tidyBrackets(result.text)
                return result
            }
        }
        result.text = tidyBrackets(result.text)
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
        case .mark(let mark):
            var body = text.trimmingCharacters(in: .whitespaces)
            while let last = body.last, markEnds.contains(last) { body.removeLast() }
            guard !body.isEmpty else { return .nothingToChange(command) }
            text = body + String(mark)
        case .replace(let old, let new):
            guard let range = lastRange(of: old, in: text) else { return .notFound(old) }
            text.replaceSubrange(range, with: new)
            // "아니, 세 시 말고 네 시": Soniox often ends the sentence before with the "아니" that starts the fix.
            text = text.replacingOccurrences(of: #"(?<=[.!?。])\s*아니[.,!?。，]*\s*$"#, with: "", options: .regularExpression)
        case .delete(let old):
            guard let range = lastRange(of: old, in: text) else { return .notFound(old) }
            text.removeSubrange(range)
            text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+([.,!?。])"#, with: "$1", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        guard text != before else { return .nothingToChange(command) }
        undo.append(before)
        return .applied(command)
    }

    /// The last place `words` were said, ignoring case and spacing: recognition spaces Korean freely, so "회의 자료"
    /// spoken in a command must still find "회의자료" in the text.
    static func lastRange(of words: String, in text: String) -> Range<String.Index>? {
        let letters = words.filter { !$0.isWhitespace }
        guard !letters.isEmpty else { return nil }
        // A mark matches its full-width form, and a comma also the spoken one.
        let pattern = letters.count == 1 && markEnds.contains(letters.first!)
            ? "[" + NSRegularExpression.escapedPattern(for: Self.sameMark(letters.first!)) + "]"
            : letters.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s*"#)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last
        return match.flatMap { Range($0.range, in: text) }
    }

    private static let sentenceEnds: Set<Character> = [".", "?", "!", "。", "…"]
    /// A spoken mark takes the place of the one Soniox put there ("내일 와요. 물음표" -> "내일 와요?").
    private static func sameMark(_ mark: Character) -> String {
        switch mark {
        case "?", "？": "?？"
        case "!", "！": "!！"
        case ".", "。": ".。"
        default: ",，" + String(PunctuationStyle.spokenComma)
        }
    }

    fileprivate static let markEnds: Set<Character> = [".", "?", "!", "。", "？", "！", ",", "，", PunctuationStyle.spokenComma]

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
