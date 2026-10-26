import DictationSpeech
import Testing
@testable import Speech2Text

private func final(_ text: String) -> SpokenTurn { SpokenTurn(text: text, isFinal: true) }
private func key(_ text: String) -> String { VoiceEditor.questionKey(final(text)) }
private func judged(_ turns: [SpokenTurn], _ verdicts: [String: CommandVerdict] = [:]) -> VoiceEditor.Result {
    VoiceEditor.apply(turns, gate: .judged(verdicts))
}

@Suite struct SpokenMarkTests {
    @Test(arguments: [
        ("물음표", Character("?")), ("물음표.", "?"), ("물음표 찍어 줘", "?"), ("느낌표!", "!"), ("마침표 찍어", "."),
        ("쉼표 넣어 주세요", PunctuationStyle.spokenComma), ("Question mark.", "?"), ("comma", PunctuationStyle.spokenComma),
    ])
    func markNamesAreCommands(utterance: String, mark: Character) {
        #expect(VoiceCommand.parse(utterance) == .mark(mark))
    }

    @Test func markNamesUsedAsWordsAreNot() {
        #expect(VoiceCommand.parse("물음표를 붙여") == nil)
        #expect(VoiceCommand.parse("물음표가 떠요") == nil)
        #expect(VoiceCommand.parse("마침표 찍는 법") == nil)
        #expect(CommandCandidate("물음표가 왜 두 개예요?") == nil)
        #expect(CommandCandidate("인생의 물음표를 찾아서") == nil)
    }

    /// Said alone after a pause, the mark takes the place of Soniox's.
    @Test func aMarkSaidAloneEndsTheSentenceWithoutAsking() {
        let result = judged([final("내일 오나요."), final("물음표.")])
        #expect(result.text == "내일 오나요?")
        #expect(result.question == nil)
        #expect(result.outcomes == [.applied(.mark("?"))])
    }

    /// Owner report (2026-10-25): with the text already ending in "?", the name "물음표" was typed as a word. The mark is
    /// already there, so it is settled without asking Jev and nothing is typed.
    @Test func aMarkTheTextAlreadyEndsWithIsNeverTyped() {
        for turns in [[final("내일 오나요? 물음표.")], [final("내일 오나요? 물음표 찍어 줘")], [final("내일 오나요?"), final("물음표?")]] {
            let result = VoiceEditor.apply(turns, gate: .judged([:], unanswered: .text))
            #expect(result.text == "내일 오나요?")
            #expect(result.question == nil)
        }
    }

    /// Nothing dictated yet: "물음표" is just a word.
    @Test func aMarkWithNothingBeforeIsTyped() {
        #expect(judged([final("물음표")]).text == "물음표")
    }

    /// "드디어 마침표" may be the word itself, so a mark said in the same sentence waits for Jev.
    @Test func aMarkInTheSameSentenceIsAskedAndJevDecides() {
        let turn = "드디어 마침표"
        let pending = judged([final(turn)])
        #expect(pending.question?.joint == .afterWord)
        #expect(pending.question?.utterance == "마침표")
        #expect(pending.text == "드디어")
        #expect(judged([final(turn)], [key(turn): .text]).text == "드디어 마침표")
        #expect(judged([final("내일 와 물음표 찍어 줘")], [key("내일 와 물음표 찍어 줘"): .command]).text == "내일 와?")
    }

    @Test func aSpokenCommaSurvivesNoCommasAndUndoRemovesTheMark() {
        let result = judged([final("네 알겠어요."), final("쉼표"), final("되돌려")])
        #expect(result.text == "네 알겠어요.")
        let comma = judged([final("네"), final("쉼표")])
        #expect(PunctuationStyle.noCommas.apply(comma.text + " 그럼요, 좋아요") == "네, 그럼요 좋아요")
        #expect(PunctuationStyle.asIs.apply(comma.text) == "네,")
    }
}
