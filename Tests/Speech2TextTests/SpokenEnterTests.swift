import Testing
@testable import Speech2Text

@Suite struct SpokenEnterTests {
    private let command = SpokenEnter(phrase: "엔터 보내기")

    @Test(arguments: [
        ("ulw 이거 고쳐 줘 엔터 보내기", "ulw 이거 고쳐 줘"),
        ("이거 고쳐 줘. 엔터보내기.", "이거 고쳐 줘."),
        ("고쳐 줘 엔터 보내기!", "고쳐 줘"),
        ("엔터 보내기", ""),
        ("그런 것 좀 알려줘. 엔터 보내기. 보내기, 엔터.", "그런 것 좀 알려줘."),
        ("이거 고쳐 줘. 보내기, 엔터.", "이거 고쳐 줘."),
    ])
    func trailingPhraseIsRemovedWhateverTheSpacingOrPunctuation(text: String, rest: String) {
        #expect(command.strip(text) == rest)
    }

    @Test(arguments: ["엔터 보내기 기능을 만들어 줘", "보내기", "", "엔터를 보내기"])
    func textNotEndingWithThePhraseIsLeftAlone(text: String) {
        #expect(command.strip(text) == nil)
    }

    /// An English UI shows "send enter" as the default, but the speaker may say the Korean command (owner's 2026-10-19 note).
    @Test func defaultCommandAcceptsEveryLanguagesDefaultPhrase() {
        let english = SpokenEnter(setting: "send enter", shownDefault: "send enter")
        #expect(english.strip("이제 잘 되나 보내기 엔터.") == "이제 잘 되나")
        #expect(english.strip("fix this, send enter") == "fix this,")
        #expect(english.terms == ["send enter", "엔터 보내기"])
        let custom = SpokenEnter(setting: "전송", shownDefault: "send enter")
        #expect(custom.strip("이제 잘 되나 보내기 엔터.") == nil)
        #expect(custom.strip("이거 고쳐 줘 전송") == "이거 고쳐 줘")
        #expect(custom.terms == ["전송"])
    }

    /// With a trigger word, Enter is pressed only when the trigger word comes right before the phrase.
    @Test func withATriggerWordThePhraseNeedsIt() {
        let command = SpokenEnter(setting: "엔터 보내기", shownDefault: "엔터 보내기", trigger: SpokenPhrase("자비스"))
        #expect(command.strip("이거 고쳐 줘. 자비스, 엔터 보내기.") == "이거 고쳐 줘.")
        #expect(command.strip("이거 고쳐 줘 엔터 보내기") == nil)
        #expect(command.strip("자비스 다음에 엔터 보내기") == nil)
        #expect(command.terms.contains("자비스"))
    }

    @Test func blankPhraseNeverMatchesAndLatinIgnoresCase() {
        #expect(SpokenEnter(phrase: " ").strip("아무 말") == nil)
        #expect(SpokenEnter(phrase: "send it").strip("fix this. Send It.") == "fix this.")
        #expect(SpokenEnter(phrase: "send it").strip("fix it send it") == "fix it")
    }
}

@Suite struct DictionaryTermsTests {
    @Test func commasAndLinesAddSeveralWordsAndDuplicatesAreSkippedInAnyCase() {
        #expect(DictionaryTerms.adding(" 센파이, omo\nULW ,,", to: ["OMO"]) == ["OMO", "센파이", "ULW"])
        #expect(DictionaryTerms.adding("  ", to: ["OMO"]) == ["OMO"])
    }

    @Test func linesFromVersion130KeepOnlyTheWrittenWord() {
        #expect(DictionaryTerms.migrating(lines: "OMO\n쏀빠이 → 센파이\nulw -> ULW\n\n센파이") == ["OMO", "센파이", "ULW"])
    }
}
