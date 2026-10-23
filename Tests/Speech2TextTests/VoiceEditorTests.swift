import DictationSpeech
import Testing
@testable import Speech2Text

private func final(_ text: String) -> SpokenTurn { SpokenTurn(text: text, isFinal: true) }
private func live(_ text: String) -> SpokenTurn { SpokenTurn(text: text, isFinal: false) }

@Suite struct VoiceEditorTests {
    @Test(arguments: [
        ("지워", VoiceCommand.deleteLastSentence), ("지워 줘.", .deleteLastSentence), ("마지막 문장 지워주세요", .deleteLastSentence),
        ("Delete that.", .deleteLastSentence), ("한 단어 지워", .deleteLastWord), ("다 지워!", .clearAll),
        ("되돌려 줘", .undo), ("Undo", .undo), ("회의를 미팅으로 바꿔 줘", .replace("회의", "미팅")),
        ("세 시를 네 시로 바꿔", .replace("세 시", "네 시")), ("replace Monday with Tuesday", .replace("Monday", "Tuesday")),
    ])
    func commandsAreRecognizedWhateverTheSpacingOrPoliteEnding(utterance: String, command: VoiceCommand) {
        #expect(VoiceCommand.parse(utterance) == command)
    }

    @Test func ordinarySentencesAreNotCommands() {
        #expect(VoiceCommand.parse("이 파일은 지워도 돼요") == nil)
        #expect(VoiceCommand.parse("내일 다시 연락드릴게요.") == nil)
        #expect(VoiceCommand.parse("") == nil)
    }

    /// The safety rule: a command counts only as a turn of its own; inside a sentence it is just text.
    @Test func aCommandInsideASentenceIsTyped() {
        let result = VoiceEditor.apply([final("오늘 회의 자료는 지워 주세요.")], commandsEnabled: true)
        #expect(result.text == "오늘 회의 자료는 지워 주세요.")
        #expect(result.outcomes.isEmpty)
    }

    @Test func deleteReplaceAndUndoEditOnlyTheDictatedText() {
        let turns = [final("첫 문장입니다."), final("둘째 문장이에요."), final("지워"), final("회의는 세 시예요."),
                     final("세 시를 네 시로 바꿔"), final("되돌려")]
        let result = VoiceEditor.apply(turns, commandsEnabled: true)
        #expect(result.text == "첫 문장입니다. 회의는 세 시예요.")
        #expect(result.outcomes == [.applied(.deleteLastSentence), .applied(.replace("세 시", "네 시")), .applied(.undo)])
    }

    @Test func lastSentenceDeletionKeepsEarlierSentencesInTheSameTurn() {
        let result = VoiceEditor.apply([final("하나. 둘? 셋"), final("지워")], commandsEnabled: true)
        #expect(result.text == "하나. 둘?")
        #expect(VoiceEditor.apply([final("hello big world"), final("delete last word")], commandsEnabled: true).text
            == "hello big")
    }

    @Test func missingTargetsAndEmptyUndoChangeNothingAndSaySo() {
        let result = VoiceEditor.apply([final("좋아요."), final("사과를 배로 바꿔"), final("되돌려")], commandsEnabled: true)
        #expect(result.text == "좋아요.")
        #expect(result.outcomes == [.notFound("사과"), .nothingToChange(.undo)])
    }

    /// A command still being recognized is never typed, so it never flashes into the field before it acts.
    @Test func aProvisionalCommandIsHeldBack() {
        #expect(VoiceEditor.apply([final("안녕하세요."), live("지워")], commandsEnabled: true).text == "안녕하세요.")
        #expect(VoiceEditor.apply([final("안녕하세요."), live("되돌")], commandsEnabled: true).text == "안녕하세요.")
        #expect(VoiceEditor.apply([final("안녕하세요."), live("내일 봬요")], commandsEnabled: true).text
            == "안녕하세요. 내일 봬요")
    }

    @Test func turnedOffEverythingIsTyped() {
        let result = VoiceEditor.apply([final("안녕하세요."), final("지워")], commandsEnabled: false)
        #expect(result.text == "안녕하세요. 지워")
        #expect(result.outcomes.isEmpty)
    }
}
