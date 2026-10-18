import DictationSpeech
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

    @Test func blankPhraseNeverMatchesAndLatinIgnoresCase() {
        #expect(SpokenEnter(phrase: " ").strip("아무 말") == nil)
        #expect(SpokenEnter(phrase: "send it").strip("fix this. Send It.") == "fix this.")
    }
}

@Suite struct VocabularyTests {
    @Test func linesBecomeTermsAndCorrections() {
        let vocabulary = Vocabulary("OMO\n\n 쏀빠이 → 센파이 \nulw -> ULW\n센파이")
        #expect(vocabulary.terms == ["OMO", "센파이", "ULW"])
        #expect(vocabulary.apply("쏀빠이에서 Ulw 실행") == "센파이에서 ULW 실행")
    }

    @Test func longerCorrectionsWinOverTheirOwnWords() {
        let vocabulary = Vocabulary("오 엠 오 → OMO\n오 → 5")
        #expect(vocabulary.apply("오 엠 오 열어") == "OMO 열어")
    }
}
