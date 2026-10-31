import Testing
@testable import Speech2Text

@Suite struct PunctuationTests {
    @Test(arguments: [
        ("네, 알겠어요. 그럼, 내일 볼까요?", "네 알겠어요. 그럼 내일 볼까요?"),
        ("Well, I think so, right? Yes!", "Well I think so right? Yes!"),
        ("가격은 1,000원, 수량은 2,500개예요.", "가격은 1,000원 수량은 2,500개예요."),
        ("좋아요，그리고、다음", "좋아요그리고다음"),
        ("a , b", "a b"),
    ])
    func noCommasDropsCommasButKeepsSentenceEndsAndNumbers(text: String, expected: String) {
        #expect(PunctuationStyle.noCommas.apply(text) == expected)
    }

    @Test(arguments: [
        ("네, 알겠어요. 그럼 내일 볼까요?", "네 알겠어요 그럼 내일 볼까요"),
        ("Pi is 3.14, see example.com! Really?", "Pi is 3.14 see example.com Really"),
        ("1,000원이에요.", "1,000원이에요"),
    ])
    func noneDropsAllButNumbersAndAddresses(text: String, expected: String) {
        #expect(PunctuationStyle.none.apply(text) == expected)
    }

    @Test func asIsLeavesTextAlone() {
        #expect(PunctuationStyle.asIs.apply("네, 1,000원. 맞죠?") == "네, 1,000원. 맞죠?")
    }
}
