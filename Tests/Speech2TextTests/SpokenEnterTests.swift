import Testing
@testable import Speech2Text

@Suite struct SpokenEnterTests {
    private let command = SpokenEnter(phrase: "엔터 보내기")

    @Test(arguments: [
        ("ulw 이거 고쳐 줘 엔터 보내기", "ulw 이거 고쳐 줘"),
        ("이거 고쳐 줘. 엔터보내기.", "이거 고쳐 줘."),
        ("고쳐 줘 엔터 보내기!", "고쳐 줘"),
        ("엔터 보내기", ""),
    ])
    func trailingPhraseIsRemovedWhateverTheSpacingOrPunctuation(text: String, rest: String) {
        #expect(command.strip(text) == rest)
    }

    @Test(arguments: ["엔터 보내기 기능을 만들어 줘", "보내기", "", "엔터를 보내기"])
    func textNotEndingWithThePhraseIsLeftAlone(text: String) {
        #expect(command.strip(text) == nil)
    }

    /// Regression: recognition wrote "센터" for a spoken "엔터", so the command never pressed Return.
    @Test func enterMisheardAsCenterStillCounts() {
        #expect(command.strip("고쳐 줘 센터 보내기.") == "고쳐 줘")
        #expect(command.strip("고쳐 줘 앤터 보내기") == "고쳐 줘")
        #expect(SpokenEnter(phrase: "보내기 엔터").strip("고쳐 줘. 보내기 센터") == "고쳐 줘.")
        #expect(command.strip("고쳐 줘 센터를 보내기") == nil)
    }

    @Test func blankPhraseNeverMatchesAndLatinIgnoresCase() {
        #expect(SpokenEnter(phrase: " ").strip("아무 말") == nil)
        #expect(SpokenEnter(phrase: "send it").strip("fix this. Send It.") == "fix this.")
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
