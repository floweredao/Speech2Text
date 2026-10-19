import Foundation

/// A phrase spoken at the very end of a dictation that presses Return after the text is typed.
/// Spacing, case and punctuation are ignored, since recognition writes "엔터 보내기", "엔터보내기." and so on.
/// "엔터" also matches the way recognition mishears it ("센터", "앤터"), which a short word after a pause often is.
struct SpokenEnter: Equatable {
    let phrase: String

    private static let misheardEnter = ["센터", "앤터"]

    func strip(_ text: String) -> String? {
        let phrase = phrase.precomposedStringWithCanonicalMapping
        let variants = [phrase] + Self.misheardEnter.map { phrase.replacingOccurrences(of: "엔터", with: $0) }
        for variant in Set(variants) {
            if let rest = Self.strip(text, phrase: variant) { return rest }
        }
        return nil
    }

    private static func strip(_ text: String, phrase: String) -> String? {
        var expected = Array(letters(phrase))
        guard !expected.isEmpty else { return nil }
        let text = text.precomposedStringWithCanonicalMapping
        var cut = text.endIndex
        while let last = expected.last {
            guard cut > text.startIndex else { return nil }
            let index = text.index(before: cut)
            let character = text[index]
            cut = index
            if isSeparator(character) { continue }
            guard Character(character.lowercased()) == last else { return nil }
            expected.removeLast()
        }
        return text[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func letters(_ text: String) -> [Character] {
        text.precomposedStringWithCanonicalMapping.lowercased().filter { !isSeparator($0) }.map { $0 }
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation
    }
}
