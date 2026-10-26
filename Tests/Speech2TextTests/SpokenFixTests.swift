import DictationSpeech
import Testing
@testable import Speech2Text

private func final(_ text: String) -> SpokenTurn { SpokenTurn(text: text, isFinal: true) }
private func key(_ text: String) -> String { VoiceEditor.questionKey(final(text)) }
private func judged(_ turns: [SpokenTurn], _ verdicts: [String: CommandVerdict] = [:]) -> VoiceEditor.Result {
    VoiceEditor.apply(turns, gate: .judged(verdicts))
}

/// Ways the user actually says edits: deleting a mark by name, brackets, and "A 아니고 B".
@Suite struct SpokenFixTests {
    @Test(arguments: ["물음표 지워", "물음표 지워 줘.", "물음표 빼", "물음표를 지워 주세요", "물음표 없애 줘"])
    func aMarkIsDeletedByItsName(utterance: String) {
        let result = judged([final("내일 오나요?"), final(utterance)])
        #expect(result.text == "내일 오나요")
        #expect(result.question == nil)
    }

    @Test func aDeletedCommaIsFoundWhetherSpokenOrRecognized() {
        #expect(judged([final("네, 좋아요."), final("쉼표 지워")]).text == "네 좋아요.")
        #expect(judged([final("네"), final("쉼표"), final("쉼표 지워")]).text == "네")
    }

    @Test(arguments: [
        ("내일 괄호 열고 오후 괄호 닫고 와요.", "내일 (오후) 와요."),
        ("회의, 괄호 열고, 온라인, 괄호 닫고 있어요.", "회의 (온라인) 있어요."),
        ("값은 괄호열고 1 괄호닫고 이에요", "값은 (1) 이에요"),
        ("call foo open paren x close paren now", "call foo (x) now"),
        ("여는 괄호 메모 닫는 괄호", "(메모)"), ("메모 여는 괄호 초안 닫는 괄호를 보세요", "메모 (초안) 보세요"),
    ])
    func bracketsAreSaidByName(spoken: String, typed: String) {
        #expect(judged([final(spoken)]).text == typed)
    }

    @Test func bracketsAcrossTurnsHugTheirWords() {
        #expect(judged([final("내일 괄호 열고."), final("오후."), final("괄호 닫고 와요.")]).text == "내일 (오후) 와요.")
    }

    @Test func bracketsAreTextWhenEditingIsOff() {
        #expect(VoiceEditor.apply([final("괄호 열고 닫고")], gate: .off).text == "괄호 열고 닫고")
    }

    @Test(arguments: [
        ("세 시 아니고 네 시", "세 시", "네 시"), ("세 시가 아니라 네 시야", "세 시", "네 시"),
        ("아니 세 시 말고 네 시", "세 시", "네 시"), ("세 시 아니, 네 시.", "세 시", "네 시"),
        ("세 시 말고 네 시로", "세 시", "네 시"), ("회의를 미팅으로 고쳐 줘", "회의", "미팅"),
        ("회의를미팅으로바꿔", "회의", "미팅"), ("세 시 대신 네 시", "세 시", "네 시"),
        ("물음표를 느낌표로 바꿔", "?", "!"),
    ])
    func corrections(utterance: String, old: String, new: String) {
        #expect(VoiceCommand.parse(utterance) == .replace(old, new))
    }

    @Test func aCorrectionReplacesTheLastPlaceOnceJevAgrees() {
        let turn = "세 시 아니고 네 시"
        let pending = judged([final("회의는 세 시예요."), final(turn)])
        #expect(pending.question != nil)
        #expect(judged([final("회의는 세 시예요."), final(turn)], [key(turn): .command]).text == "회의는 네 시예요.")
        // Never said, so it is plain text without asking.
        #expect(judged([final("좋아요."), final(turn)]).text == "좋아요. 세 시 아니고 네 시")
    }

    @Test func theNoThatStartsACorrectionIsDroppedWhenSonioxEndsTheSentenceWithIt() {
        let turn = "3시 말고 4시."
        #expect(judged([final("회의는 3시에 시작해요. 아니."), final(turn)], [key(turn): .command]).text == "회의는 4시에 시작해요.")
    }

    @Test func sentencesThatOnlySoundLikeCorrectionsAreNot() {
        #expect(VoiceCommand.parse("이건 사과가 아니라 배라고 생각해요 그리고 내일 봐요 정말로요 진짜") == nil)
        #expect(VoiceCommand.parse("아니요") == nil)
        #expect(VoiceCommand.parse("괄호 열고") == nil)
        #expect(VoiceCommand.parse("시가 아니라 4시야.") == nil)
    }

    @Test(arguments: [
        ("방금 거 삭제해 주세요", VoiceCommand.deleteLastSentence), ("앞 문장 좀 날려 줘", .deleteLastSentence),
        ("마지막 문장을 지워 버려", .deleteLastSentence), ("그 부분 빼 줘", .deleteLastSentence), ("scratch this", .deleteLastSentence),
        ("마지막 단어 삭제", .deleteLastWord), ("한 글자 지워 줘", .deleteLastCharacter), ("전부 날려", .clearAll),
        ("싹 다 지워 주세요", .clearAll), ("clear everything", .clearAll), ("방금 거 취소", .undo), ("원래대로 돌려놔", .undo),
        ("되돌려 주세요", .undo), ("물음표 하나 붙여 줘", .mark("?")), ("콜론 찍어", .mark(":")), ("add question mark", .mark("?")),
    ])
    func anEditIsReadFromItsObjectAndVerbHoweverItIsSaid(utterance: String, command: VoiceCommand) {
        #expect(VoiceCommand.parse(utterance) == command)
    }

    @Test(arguments: [
        ("회의 부분을 미팅으로 수정해 주세요", "회의", "미팅"), ("세 시 네 시로 바꿔", "세 시", "네 시"),
        ("회의 대신 미팅으로 바꿔 줘", "회의", "미팅"), ("change meeting to call", "meeting", "call"),
        ("아, 세 시 아니고요 네 시", "세 시", "네 시"), ("meeting, I mean call", "meeting", "call"),
        ("api 대문자로 바꿔", "api", "API"), ("회의 자료 붙여 써", "회의 자료", "회의자료"),
    ])
    func aFixIsReadHoweverItIsSaid(utterance: String, old: String, new: String) {
        #expect(VoiceCommand.parse(utterance) == .replace(old, new))
    }

    @Test(arguments: [("회의라는 단어 지워", "회의"), ("회의를 좀 삭제해 줘", "회의"), ("remove the word meeting", "meeting")])
    func aNamedWordIsDeletedHoweverItIsSaid(utterance: String, word: String) {
        #expect(VoiceCommand.parse(utterance) == .delete(word))
    }

    @Test func quotesAreSaidByName() {
        #expect(judged([final("그는 따옴표 열고 안녕 따옴표 닫고 라고 했다")]).text == "그는 “안녕” 라고 했다")
    }

    @Test(arguments: ["취소", "돌려 줘", "yes, no problem", "그거 정말 좋다", "대문자", "다음 주 회의 자료 붙여서 보내"])
    func everydayWordsAreNoEdit(utterance: String) {
        #expect(VoiceCommand.parse(utterance) == nil)
    }

    @Test(arguments: [
        (["회의 끝났어요. 물음표.", "찍어."], "회의 끝났어요?"),
        (["배포는 오늘 저녁에 할게요. 오늘.", "을 지워 줘."], "배포는 저녁에 할게요."),
        (["회의 끝났어요. 물음.", "표."], "회의 끝났어요?"),
    ])
    func aCommandSonioxSplitAcrossTurnsIsJoined(said: [String], typed: String) {
        let turns = VoiceEditor.joiningSplitCommands(said.map(final))
        #expect(judged(said.map(final), [key(turns.last!.text): .command]).text == typed)
    }

    @Test func anEditTakenBackInTheSameBreathLeavesTheText() {
        #expect(judged([final("오늘 회의는 3시예요."), final("지워. 되돌려 줘.")]).text == "오늘 회의는 3시예요.")
    }

    @Test func aTurnIsNotJoinedWhenItIsTextOnItsOwnAndTogether() {
        let turns = [final("내일 서울역에서 봬요."), final("이거 정말 좋아요.")]
        #expect(VoiceEditor.joiningSplitCommands(turns) == turns)
    }
}
