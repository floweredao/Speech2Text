import DictationSpeech
import Testing
@testable import Speech2Text

private func final(_ text: String) -> SpokenTurn { SpokenTurn(text: text, isFinal: true) }
private func live(_ text: String) -> SpokenTurn { SpokenTurn(text: text, isFinal: false) }

@Suite struct VoiceEditorTests {
    @Test(arguments: [
        ("지워", VoiceCommand.deleteLastSentence), ("지워 줘.", .deleteLastSentence), ("마지막 문장 지워주세요", .deleteLastSentence),
        ("Delete that.", .deleteLastSentence), ("방금 말한 거 지워.", .deleteLastSentence), ("방금 한 말 지워 줘", .deleteLastSentence),
        ("한 단어 지워", .deleteLastWord), ("다 지워!", .clearAll),
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

    /// The safety rule: a command counts only right after the trigger word; without it the same words are text.
    @Test func aCommandWithoutTheTriggerWordIsTyped() {
        let inside = apply([final("오늘 회의 자료는 지워 주세요.")])
        #expect(inside.text == "오늘 회의 자료는 지워 주세요.")
        #expect(inside.outcomes.isEmpty)
        let alone = apply([final("안녕하세요."), final("지워")])
        #expect(alone.text == "안녕하세요. 지워")
        #expect(alone.outcomes.isEmpty)
    }

    @Test func deleteReplaceAndUndoEditOnlyTheDictatedText() {
        let turns = [final("첫 문장입니다."), final("둘째 문장이에요."), final("자비스 지워"), final("회의는 세 시예요."),
                     final("자비스, 세 시를 네 시로 바꿔"), final("자비스 되돌려")]
        let result = apply(turns)
        #expect(result.text == "첫 문장입니다. 회의는 세 시예요.")
        #expect(result.outcomes == [.applied(.deleteLastSentence), .applied(.replace("세 시", "네 시")), .applied(.undo)])
    }

    /// Soniox may keep the trigger word in the sentence's turn or give the command a turn of its own.
    @Test func theCommandMayFollowInTheSameTurnOrTheNext() {
        let sameTurn = apply([final("하나. 둘? 셋 자비스 지워")])
        #expect(sameTurn.text == "하나. 둘?")
        #expect(sameTurn.outcomes == [.applied(.deleteLastSentence)])
        let nextTurn = apply([final("hello big world."), final("자비스."), final("delete last word")])
        #expect(nextTurn.text == "hello big")
        #expect(nextTurn.outcomes == [.applied(.deleteLastWord)])
    }

    @Test(arguments: [("세 시 지워", "세 시"), ("'급히'를 지워 주세요.", "급히"), ("회의 자료 빼 줘", "회의 자료"),
                      ("delete Monday", "Monday")])
    func aNamedPartCanBeDeleted(utterance: String, target: String) {
        #expect(VoiceCommand.parse(utterance) == .delete(target))
    }

    /// Only the last place the words were said goes, found whatever the recognizer did with the spaces, and the
    /// sentence around it closes up.
    @Test func deletingANamedPartRemovesOnlyItsLastOccurrence() {
        let result = apply([final("세 시에 봐요. 회의는 급히 세시예요."), final("자비스 급히 지워"), final("자비스 세 시를 지워"),
                            final("자비스 사과 지워")])
        #expect(result.text == "세 시에 봐요. 회의는 예요.")
        #expect(result.outcomes == [.applied(.delete("급히")), .applied(.delete("세 시")), .notFound("사과")])
    }

    @Test func missingTargetsAndEmptyUndoChangeNothingAndSaySo() {
        let result = apply([final("좋아요."), final("자비스 사과를 배로 바꿔"), final("자비스 되돌려")])
        #expect(result.text == "좋아요.")
        #expect(result.outcomes == [.notFound("사과"), .nothingToChange(.undo)])
    }

    /// Words after the trigger word that are no command are typed as said, trigger word included.
    @Test func wordsAfterTheTriggerWordThatAreNoCommandAreTyped() {
        let result = apply([final("자비스 고마워요.")])
        #expect(result.text == "자비스 고마워요.")
        #expect(result.outcomes.isEmpty)
    }

    /// Nothing after the trigger word is typed before Soniox finalizes it, so a command never flashes into the field.
    @Test func aProvisionalCommandIsHeldBack() {
        #expect(apply([final("안녕하세요."), live("자비스 지워")]).text == "안녕하세요.")
        #expect(apply([final("안녕하세요."), live("자비스")]).text == "안녕하세요.")
        #expect(apply([final("안녕하세요."), final("자비스"), live("되돌")]).text == "안녕하세요.")
        #expect(apply([final("안녕하세요."), live("내일 봬요 자비")]).text == "안녕하세요. 내일 봬요")
        #expect(apply([final("안녕하세요."), live("내일 봬요")]).text == "안녕하세요. 내일 봬요")
        #expect(apply([final("안녕하세요."), final("내일 봬요 자비")]).text == "안녕하세요. 내일 봬요 자비")
    }

    @Test func turnedOffEverythingIsTyped() {
        let result = VoiceEditor.apply([final("안녕하세요."), final("자비스 지워")], commandsEnabled: false, trigger: trigger)
        #expect(result.text == "안녕하세요. 자비스 지워")
        #expect(result.outcomes.isEmpty)
    }
}

private let trigger = SpokenPhrase("자비스")
private func apply(_ turns: [SpokenTurn]) -> VoiceEditor.Result {
    VoiceEditor.apply(turns, commandsEnabled: true, trigger: trigger)
}
