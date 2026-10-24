import Testing
@testable import Speech2Text

@Suite struct SpokenPhraseTests {
    private let wake = SpokenPhrase("Hey Kidamo", alternates: ["헤이 키다모"])

    @Test func anySpellingRecognitionWritesEndsTheText() {
        #expect(wake.strippingSuffix("오늘은 여기까지예요. Hey, Kidamo.") == "오늘은 여기까지예요.")
        #expect(wake.strippingSuffix("오늘은 여기까지 헤이키다모") == "오늘은 여기까지")
        #expect(wake.strippingSuffix("HEY KIDAMO!") == "")
    }

    @Test func thePhraseMustStartAWordAndEndTheText() {
        #expect(wake.strippingSuffix("오헤이 키다모") == nil)
        #expect(wake.strippingSuffix("Hey Kidamo, 이건 계속 써요") == nil)
        #expect(wake.strippingSuffix("hey kid") == nil)
    }

    @Test func splitKeepsTheDictatedPunctuationAndDropsTheLeadIn() throws {
        let trigger = SpokenPhrase("자비스")
        let split = try #require(trigger.split("회의는 세 시예요. 자비스, 지워 줘."))
        #expect(split.before == "회의는 세 시예요.")
        #expect(split.after == "지워 줘")
        #expect(trigger.split("자비스가 왔어요") != nil)
        #expect(trigger.split("오늘은 자비 없이") == nil)
    }

    /// Live typing waits while the end of the text could still become the phrase.
    @Test func aPartialPhraseAtTheEndIsFound() {
        let text = "내일 봬요 헤이 키"
        #expect(wake.partialSuffixStart(text).map { String(text[$0...]) } == "헤이 키")
        #expect(wake.partialSuffixStart("내일 봬요 헤") == nil)
        #expect(wake.partialSuffixStart("내일 봬요") == nil)
    }

    @Test func anEmptyPhraseNeverMatches() {
        let empty = SpokenPhrase("  ")
        #expect(empty.isEmpty)
        #expect(empty.split("지워") == nil)
        #expect(empty.strippingSuffix("지워") == nil)
    }
}
