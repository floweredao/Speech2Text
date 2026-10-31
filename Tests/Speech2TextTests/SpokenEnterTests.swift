import Foundation
import Testing
@testable import Speech2Text

@Suite struct SpokenEnterTests {
    private let command = SpokenEnter(phrase: "엔터 보내기")

    @Test(arguments: [
        ("xcode 이거 고쳐 줘 엔터 보내기", "xcode 이거 고쳐 줘"),
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

    /// An English UI shows "send enter" as the default, but the speaker may say the Korean command.
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

    @Test func blankPhraseNeverMatchesAndLatinIgnoresCase() {
        #expect(SpokenEnter(phrase: " ").strip("아무 말") == nil)
        #expect(SpokenEnter(phrase: "send it").strip("fix this. Send It.") == "fix this.")
        #expect(SpokenEnter(phrase: "send it").strip("fix it send it") == "fix it")
    }
}

@Suite struct DictionaryTermsTests {
    @Test func commasAndLinesAddSeveralWordsAndDuplicatesAreSkippedInAnyCase() {
        #expect(DictionaryTerms.adding(" 쿠버네티스, swiftui\nXcode ,,", to: ["SwiftUI"]) == ["SwiftUI", "쿠버네티스", "Xcode"])
        #expect(DictionaryTerms.adding("  ", to: ["SwiftUI"]) == ["SwiftUI"])
    }

    @Test func linesFromVersion130KeepOnlyTheWrittenWord() {
        #expect(DictionaryTerms.migrating(lines: "SwiftUI\n쿠베네티스 → 쿠버네티스\nxcode -> Xcode\n\n쿠버네티스") == ["SwiftUI", "쿠버네티스", "Xcode"])
    }

    @MainActor @Test func aFreshInstallStartsWithAnEmptyDictionary() throws {
        let defaults = try #require(UserDefaults(suiteName: "DictionaryTermsTests-\(UUID().uuidString)"))
        #expect(AppModel.storedDictionary(defaults).isEmpty)
        defaults.set("SwiftUI\nxcode -> Xcode", forKey: "vocabulary")
        #expect(AppModel.storedDictionary(defaults) == ["SwiftUI", "Xcode"])
        defaults.set(["쿠버네티스"], forKey: "dictionaryTerms")
        #expect(AppModel.storedDictionary(defaults) == ["쿠버네티스"])
    }
}
