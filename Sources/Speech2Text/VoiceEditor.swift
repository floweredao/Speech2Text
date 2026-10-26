import DictationSpeech
import Foundation

/// A hands-free edit of the text dictated so far. See DESIGN.md, "말로 고치기".
enum VoiceCommand: Equatable {
    case deleteLastSentence, deleteLastWord, deleteLastCharacter, clearAll, undo
    case replace(String, String)
    /// "A 지워" / "delete A": removes the last A in the dictated text.
    case delete(String)
    /// A punctuation mark said by name ("물음표", "question mark"), put at the end of the dictated text.
    case mark(Character)

    // MARK: Grammar
    //
    // An edit is read as object + verb + ending rather than a list of whole phrases, so the many ways one edit is said
    // ("방금 거 삭제해 주세요", "앞 문장 좀 날려 줘", "그 부분 빼 버려") all land on it. Jev still decides whether
    // the words are an edit or part of the message; this only finds what the edit would be. See DESIGN.md, "말로 고치기".

    /// Verb forms compared without spaces; each counts as its canonical verb.
    private static let deleteVerbs = ["지워버려", "지워버리기", "지워라", "지우세요", "지우기", "지워", "지움",
                                      "삭제해", "삭제하기", "삭제", "제거해", "제거", "없애버려", "없애", "날려버려",
                                      "날려", "빼버려", "빼", "떼", "취소해", "취소"]
    private static let undoVerbs = ["되돌려", "되돌리기", "되돌리세요", "돌려놔", "원래대로해", "원래대로",
                                    "원상복구해", "원상복구", "실행취소", "undo", "revert"]
    /// Endings and softeners said after the verb; recognition spaces them freely ("지워 줘", "지워줘요").
    private static let endings = ["주실래요", "주세요", "줄래요", "줄래", "줘요", "줘봐", "줘", "봐요", "봐", "요", "라", "줄래"]
    /// Softeners said between the object and the verb ("방금 거 좀 지워").
    private static let fillers = ["좀", "그냥", "다시", "얼른", "빨리"]

    private static let sentenceObjects = ["", "그거", "이거", "저거", "방금", "방금거", "방금것", "방금그거", "그문장",
                                          "이문장", "문장", "마지막문장", "앞문장", "앞에문장", "전문장", "직전문장",
                                          "방금문장", "방금말", "방금말한거", "방금말한것", "방금한말", "방금말한문장",
                                          "말한거", "마지막말", "그말", "방금쓴거", "방금쓴문장", "마지막거", "그부분",
                                          "이부분", "방금부분", "한문장", "마지막한문장"]
    private static let wordObjects = ["단어", "한단어", "마지막단어", "끝단어", "앞단어", "방금단어", "그단어",
                                      "마지막한단어", "끝에단어", "단어하나", "단어한개", "끝말", "마지막낱말", "낱말"]
    private static let characterObjects = ["글자", "한글자", "마지막글자", "끝글자", "마지막한글자", "끝에글자", "글자하나"]
    private static let allObjects = ["다", "전부", "모두", "전체", "싹", "싹다", "전부다", "모두다", "전체다",
                                     "몽땅", "글전부", "처음부터다", "다전부", "통째로", "전체글", "모든글"]
    /// Undo also said as "방금 거 취소" — "취소" alone stays a deletion of the last sentence.
    private static let undoObjects = ["", "원래대로", "방금거", "방금것", "그거", "편집", "방금편집", "수정"]

    private static let english: [(VoiceCommand, [String])] = [
        (.deleteLastSentence, ["deletethat", "scratchthat", "deletelastsentence", "deletethelastsentence",
                               "removethat", "erasethat", "deletethis", "scratchthis", "deletethesentence",
                               "removethelastsentence", "deletewhatisaid", "takethatback"]),
        (.deleteLastWord, ["deletelastword", "deleteword", "deletethelastword", "removethelastword", "removelastword",
                           "erasethelastword", "backspaceword"]),
        (.deleteLastCharacter, ["deletelastletter", "deletethelastletter", "deletelastcharacter", "backspace"]),
        (.clearAll, ["clearall", "deleteall", "deleteeverything", "cleareverything", "eraseeverything",
                     "removeeverything", "clearthat"]),
        (.undo, ["undo", "undothat", "undothelastedit", "revertthat", "putitback"]),
    ]

    /// Mark names, compared like the phrases. A name with a particle ("물음표를") or inside a sentence is text.
    private static let markNames: [(Character, [String])] = [
        ("?", ["물음표", "questionmark"]),
        ("!", ["느낌표", "exclamationmark", "exclamationpoint"]),
        (".", ["마침표", "온점", "fullstop", "period"]),
        (PunctuationStyle.spokenComma, ["쉼표", "반점", "comma"]),
        (":", ["콜론", "colon"]),
        ("~", ["물결표", "물결"]),
        ("…", ["말줄임표", "줄임표", "점점점", "ellipsis"]),
    ]
    /// "물음표 찍어", "쉼표 넣어 줘", "물음표 하나 붙여".
    private static let markVerbs = ["", "찍어", "찍기", "붙여", "넣어", "추가", "추가해", "달아", "쳐", "하나", "하나찍어",
                                    "하나붙여", "하나넣어", "로끝내", "으로끝내", "로끝내기", "add", "insert", "put"]
    /// Words the recognizer gets as context so the commands are heard as written.
    static let terms = ["지워", "되돌려", "바꿔", "물음표", "느낌표", "마침표", "쉼표", "괄호", "괄호 열고", "괄호 닫고",
                        "따옴표", "고쳐", "삭제해"]

    /// The mark a word names ("물음표" -> "?"), so "물음표 지워" finds the "?" in the text.
    static func markNamed(_ word: String) -> Character? {
        let compact = normalized(word)
        return markNames.first { $0.1.contains(compact) }?.0
    }

    private static func target(_ word: Substring) -> String {
        let word = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ ,，"))
        return markNamed(word).map(String.init) ?? word
    }

    /// Lower-cased, without spaces, punctuation or an ending: recognition spaces Korean freely ("지워 줘", "지워줘").
    static func normalized(_ text: String) -> String {
        var compact = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        if compact.hasPrefix("please") { compact.removeFirst(6) }
        if compact.hasSuffix("please") { compact.removeLast(6) }
        for ending in endings where compact.hasSuffix(ending) && compact.count > ending.count {
            compact.removeLast(ending.count)
            break
        }
        return compact
    }

    /// The object before a verb form at the end of `compact`, with softeners and an object particle dropped.
    private static func object(in compact: String, verbs: [String]) -> String? {
        guard let verb = verbs.first(where: { compact.hasSuffix($0) }) else { return nil }
        var object = String(compact.dropLast(verb.count))
        var changed = true
        while changed {
            changed = false
            for word in fillers + ["을", "를", "은", "는"] where object.hasSuffix(word) && object.count > word.count {
                object.removeLast(word.count)
                changed = true
            }
            for word in fillers where object.hasPrefix(word) && object.count > word.count {
                object.removeFirst(word.count)
                changed = true
            }
        }
        return fillers.contains(object) ? "" : object
    }

    static func parse(_ utterance: String) -> VoiceCommand? {
        let compact = normalized(utterance)
        guard !compact.isEmpty else { return nil }
        if let match = english.first(where: { $0.1.contains(compact) }) { return match.0 }
        if let object = object(in: compact, verbs: undoVerbs), undoObjects.contains(object) { return .undo }
        // "방금 거 취소" undoes; "취소" with another object ("그 문장 취소") deletes.
        if compact.hasSuffix("취소"), let object = object(in: compact, verbs: ["취소해", "취소"]),
           undoObjects.contains(object), !object.isEmpty { return .undo }
        if let object = object(in: compact, verbs: deleteVerbs) {
            if sentenceObjects.contains(object) { return object.isEmpty && compact.hasPrefix("취소") ? nil : .deleteLastSentence }
            if wordObjects.contains(object) { return .deleteLastWord }
            if characterObjects.contains(object) { return .deleteLastCharacter }
            if allObjects.contains(object) { return .clearAll }
        }
        for (mark, names) in markNames {
            if names.contains(where: { name in markVerbs.contains { name + $0 == compact || $0 + name == compact } }) {
                return .mark(mark)
            }
        }
        return replacement(in: utterance) ?? deletion(in: utterance)
    }

    // Regex pieces shared by the targeted edits.
    private static let ending = #"(?:\s*(?:버려|버리고))?(?:\s*(?:주실래요|주세요|줄래요|줄래|줘요|줘|봐요|봐))?(?:요|라)?\s*[.!?。]*\s*$"#
    private static let softener = #"(?:\s*(?:좀|그냥|다시|얼른|빨리))?"#
    /// "A라는 단어", "A라고 한 거", "A 부분": what the speaker calls the target is not part of it.
    private static let noun = #"(?:\s*(?:이?라는|이?란|이?라고\s*(?:한|쓴|된|적은)?)\s*(?:단어|말|글자|부분|거|것|문장)?|\s*(?:부분|단어|글자|낱말)(?=\s*(?:을|를|은|는|이|가|대신|\s)))?"#
    private static let deleteVerb = #"(?:지워|지우세요|지우기|빼|삭제\s*해|삭제|제거\s*해|제거|없애|떼|날려)"#
    private static let replaceVerb = #"(?:바꿔|바꾸세요|바꾸기|바꺼|고쳐|고치세요|수정\s*해|수정|변경\s*해|변경|교체\s*해|교체|정정\s*해|정정)"#

    private static func regexes(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    private static let deletePatterns = regexes([
        #"^\s*(.{1,30}?)"# + noun + #"\s*(?:을|를|은|는|이|가)?"# + softener + #"\s*"# + deleteVerb + ending,
        #"^\s*(?:please\s+)?(?:delete|remove|erase|take\s+out|get\s+rid\s+of)\s+(?:the\s+word\s+)?(.{1,30}?)\s*(?:please)?\s*[.!?]*\s*$"#,
    ])

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

    /// Index of the "say it again" pattern, whose one-letter A is refused.
    private static let againPattern = 3
    private static let replacePatterns = regexes([
        // "A를 B로 바꿔", "A 부분을 B라고 고쳐 줘", "A 대신 B로 바꿔".
        #"^\s*(.{1,30}?)"# + noun + #"\s*(?:을|를|대신에|대신)"# + softener + #"\s*(.{1,30}?)\s*(?:으로|로|이라고|라고)"# + softener + #"\s*"# + replaceVerb + ending,
        // "A B로 바꿔": no particle after A, common in speech.
        #"^\s*(\S.{0,29}?)\s+(.{1,30}?)\s*(?:으로|로|이라고|라고)"# + softener + #"\s*"# + replaceVerb + ending,
        #"^\s*(?:please\s+)?(?:replace|change|swap)\s+(.{1,30}?)\s+(?:with|to|for|into)\s+(.{1,30}?)\s*(?:please)?\s*[.!?]*\s*$"#,
        // Correcting by saying it again: "세 시 아니고 네 시", "아니 세 시 말고 네 시로", "세 시가 아니라 네 시야",
        // "아, 세 시 아니고요 네 시", "세 시 대신 네 시".
        #"^\s*(?:(?:아니|아|어|정정|수정)\s*[,，]?\s+)?(.{1,15}?)\s*(?:이|가)?\s*(?:아니고요|아니구|아니고|아니라|아니에요[,，.]?|말고요|말고|아니[,，]|아니(?=\s)|대신에|대신)\s*[,，]?\s*(.{1,15}?)\s*(?:으로|로|이요|이야|이에요|예요|야|요)?\s*[.!?。]*\s*$"#,
        #"^\s*(?:not\s+)?(.{1,20}?)\s*[,，]?\s+(?:i\s+mean|i\s+meant|sorry|rather)\s*[,，]?\s+(.{1,20}?)\s*[.!?]*\s*$"#,
        #"^\s*not\s+(.{1,20}?)\s*[,，]?\s+but\s+(.{1,20}?)\s*[.!?]*\s*$"#,
    ])

    private static func replacement(in utterance: String) -> VoiceCommand? {
        let range = NSRange(utterance.startIndex..., in: utterance)
        for (index, pattern) in replacePatterns.enumerated() {
            guard let match = pattern.firstMatch(in: utterance, range: range),
                  let oldRange = Range(match.range(at: 1), in: utterance),
                  let newRange = Range(match.range(at: 2), in: utterance)
            else { continue }
            let (old, new) = (Self.target(utterance[oldRange]), Self.target(utterance[newRange]))
            guard !old.isEmpty, !new.isEmpty else { continue }
            // "세 시 네 시로 바꿔" has no particle telling where A ends: a fix mostly swaps like for like, so an even
            // number of words splits in half, an odd number after the first word.
            if index == 1 {
                let words = (old + " " + new).split(whereSeparator: \.isWhitespace)
                let cut = words.count % 2 == 0 ? words.count / 2 : 1
                return .replace(words.prefix(cut).joined(separator: " "), written(words.dropFirst(cut).joined(separator: " "), for: words.prefix(cut).joined(separator: " ")))
            }
            // A one-letter "A 아니고 B" is mostly a word Soniox split ("3. / 시가 아니라 4시"); it would cut into another word.
            if index >= againPattern, old.count < 2, markNamed(old) == nil { continue }
            return .replace(old, written(new, for: old))
        }
        return spacing(in: utterance)
    }

    /// "대문자로 바꿔" / "소문자로": the new words are the old ones in that case.
    private static func written(_ new: String, for old: String) -> String {
        switch normalized(new) {
        case "대문자", "uppercase", "capitals", "allcaps", "caps": old.uppercased()
        case "소문자", "lowercase": old.lowercased()
        case "첫글자대문자", "capitalized": old.prefix(1).uppercased() + old.dropFirst()
        default: new
        }
    }

    private static let spacingPatterns = regexes([
        // "회의 자료 붙여 써" -> "회의자료".
        #"^\s*(.{2,30}?)\s*(?:을|를)?\s*(?:붙여서|붙여)\s*(?:써|쓰기|적어|써요)"# + ending,
        // "회의 자료 띄어 써" -> "회의 자료", found also where it was typed as "회의자료".
        #"^\s*(.{2,30}?)\s*(?:을|를)?\s*(?:띄어서|띄어)\s*(?:써|쓰기|적어|써요)"# + ending,
    ])

    private static func spacing(in utterance: String) -> VoiceCommand? {
        let range = NSRange(utterance.startIndex..., in: utterance)
        for (index, pattern) in spacingPatterns.enumerated() {
            guard let match = pattern.firstMatch(in: utterance, range: range),
                  let words = Range(match.range(at: 1), in: utterance) else { continue }
            let old = String(utterance[words]).trimmingCharacters(in: .whitespaces)
            guard old.contains(where: \.isWhitespace) || index == 0 else { continue }
            return .replace(old, index == 0 ? old.filter { !$0.isWhitespace } : old)
        }
        return nil
    }
}

/// Turns spoken turns into the text to type. A finished turn ending in a command of an action that is on waits for
/// Jev's verdict; commands of actions that are off are typed as said. See DESIGN.md, "말로 고치기".
struct VoiceEditor {
    enum Gate: Equatable {
        case off
        /// Verdicts Jev gave so far, by `CommandQuestion.key`; `unanswered` settles turns not answered yet instead of
        /// waiting for them. Only commands of `actions` are performed or asked about.
        case judged([String: CommandVerdict], unanswered: CommandVerdict? = nil, actions: Set<VoiceAction> = VoiceAction.edits)
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

    static func apply(_ turns: [SpokenTurn], gate: Gate) -> Result {
        if case .judged(let verdicts, let unanswered, let actions) = gate {
            return judged(turns, verdicts: verdicts, unanswered: unanswered, actions: actions)
        }
        var result = Result()
        for turn in turns {
            append(turn.text.trimmingCharacters(in: .whitespacesAndNewlines), to: &result.text)
        }
        result.text = tidyBrackets(result.text)
        return result
    }

    private static let bracketWords: [(NSRegularExpression, String)] = [
        (#"[,，.。]?\s*(?:소?괄호\s*(?:를|을)?\s*(?:열고|열어서|열어|열기|시작하고|시작)|여는\s*괄호|open\s+(?:paren(?:thesis)?|bracket))\s*[,，.。]?"#, " ("),
        (#"[,，.。]?\s*(?:소?괄호\s*(?:를|을)?\s*(?:닫고|닫아서|닫아|닫기|끝)|닫는\s*괄호(?:를|을)?|close\s+(?:paren(?:thesis)?|bracket))\s*[,，]?"#, ") "),
        (#"[,，.。]?\s*(?:(?:큰|작은)?\s*따옴표\s*(?:를|을)?\s*(?:열고|열어서|열어|열기|시작하고|시작)|여는\s*(?:큰|작은)?\s*따옴표|open\s+quotes?|begin\s+quote)\s*[,，.。]?"#, " “"),
        (#"[,，.。]?\s*(?:(?:큰|작은)?\s*따옴표\s*(?:를|을)?\s*(?:닫고|닫아서|닫아|닫기|끝)|닫는\s*(?:큰|작은)?\s*따옴표(?:를|을)?|close\s+quotes?|end\s+quote|unquote)\s*[,，]?"#, "” "),
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
        guard text.contains(where: { "()“”".contains($0) }) else { return text }
        return text.replacingOccurrences(of: #"([(“])\s+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[,，.。]?\s+([)”])"#, with: "$1", options: .regularExpression)
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
        case .mark(let mark):
            let body = before.trimmingCharacters(in: .whitespaces)
            if body.isEmpty { return .text }
            // "내일 와요? 물음표": the text already ends in the mark, so the name only confirms it. Asking Jev could
            // type the word "물음표" after the "?"; nothing changes either way, so it is never typed.
            if let last = body.last, sameMark(mark).contains(last) { return .command }
            return joint == .ownChunk ? .command : nil
        case .undo: return canUndo ? (afterEdit ? .command : nil) : .text
        case .replace(let old, _) where VoiceEditor.lastRange(of: old, in: before) == nil: return .text
        case .delete(let old) where VoiceEditor.lastRange(of: old, in: before) == nil: return .text
        // "물음표 지워" names a mark the text holds; it is never part of a message, and "되돌려" brings it back.
        case .delete(let old) where old.count == 1 && VoiceEditor.markEnds.contains(old.first!): return .command
        // "테스트 데이터 있잖아. 그거 지워": the speaker points the reader at a thing, so what follows is about that thing.
        case _ where pointsAtAThing(before): return .text
        default: return before.trimmingCharacters(in: .whitespaces).isEmpty ? .text : nil
        }
    }

    private static let pointer = try! NSRegularExpression(
        pattern: #"(?:있잖아|있잖아요|말이야|말이에요|말인데|봤어|봤지|알지|알죠|기억나|기억나지|있지|있죠)\s*[.?!。？！]*\s*$"#)

    /// The last sentence before ends by pointing the reader at something ("~ 있잖아", "~ 말이야", "~ 봤어?").
    static func pointsAtAThing(_ before: String) -> Bool {
        pointer.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) != nil
    }

    /// Soniox often ends a turn inside a command when the speaker pauses in it ("… 근처." / "삭제해 주세요",
    /// "오늘." / "을 지워 줘", "물음." / "표"): the end of the turn before is joined back when only together they
    /// name an edit with its own target.
    static func joiningSplitCommands(_ turns: [SpokenTurn]) -> [SpokenTurn] {
        var joined: [SpokenTurn] = []
        for turn in turns {
            guard let previous = joined.last, previous.isFinal, turn.isFinal else {
                joined.append(turn)
                continue
            }
            let current = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A fragment that starts with the particle or the syllable the turn before broke off ("을 지워", "표.").
            let tight = current.range(of: #"^(?:을|를|이|가|은|는|표)(?:\s|[.,!?。]|$)"#, options: .regularExpression) != nil
            // A turn that is an edit on its own ("지워") stays one; only a fragment is joined.
            let alone = tight ? nil : VoiceCommand.parse(current)
            guard alone == nil else {
                joined.append(turn)
                continue
            }
            var head = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = head.last, last.isPunctuation || last.isWhitespace { head.removeLast() }
            let cut = head.lastIndex(where: { ".!?。,，".contains($0) })
            let clause = String(cut.map { head[head.index(after: $0)...] } ?? head[...]).trimmingCharacters(in: .whitespaces)
            guard !clause.isEmpty, clause.split(whereSeparator: \.isWhitespace).count <= 3 else {
                joined.append(turn)
                continue
            }
            let together = clause + (tight ? "" : " ") + current
            guard let command = VoiceCommand.parse(together), command != .deleteLastSentence else {
                joined.append(turn)
                continue
            }
            let rest = cut.map { String(head[...$0]) } ?? ""
            joined[joined.count - 1] = SpokenTurn(text: rest, isFinal: true, pauseBeforeMs: previous.pauseBeforeMs)
            joined.append(SpokenTurn(text: together, isFinal: true, pauseBeforeMs: turn.pauseBeforeMs))
        }
        return joined
    }

    private static func judged(_ turns: [SpokenTurn], verdicts: [String: CommandVerdict], unanswered: CommandVerdict?,
                               actions: Set<VoiceAction>) -> Result {
        var result = Result()
        var undo: [String] = []
        var afterEdit = false
        for turn in joiningSplitCommands(turns) {
            let spoken = brackets(turn.text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !spoken.isEmpty else { continue }
            // "지워. 되돌려": the speaker took the edit back in the same breath, so neither is typed.
            if let candidate = CommandCandidate(spoken), turn.isFinal, case .undo = candidate.command, undo.isEmpty,
               actions.contains(.undo), let taken = CommandCandidate(candidate.before), taken.command != .undo,
               actions.contains(taken.command.action) {
                append(taken.before, to: &result.text)
                afterEdit = false
                continue
            }
            // A command whose action is off is ordinary words, never held back or asked about.
            guard let candidate = CommandCandidate(spoken), actions.contains(candidate.command.action) else {
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
        case .deleteLastCharacter:
            var body = text.trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { body.removeLast() }
            text = body.trimmingCharacters(in: .whitespaces)
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
            text = text.replacingOccurrences(of: #"(?<=[.!?。])\s*(?:아니|아|어|음)[.,!?。，]*\s*$"#, with: "", options: .regularExpression)
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
    static func sameMark(_ mark: Character) -> String {
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
