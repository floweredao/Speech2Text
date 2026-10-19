import Foundation

/// A phrase spoken at the very end of a dictation that presses Return after the text is typed.
/// Spacing, case and punctuation are ignored, since recognition writes "엔터 보내기", "엔터보내기." and so on.
struct SpokenEnter: Equatable {
    let phrase: String

    func strip(_ text: String) -> String? {
        var expected = Array(Self.letters(phrase))
        guard !expected.isEmpty else { return nil }
        let text = text.precomposedStringWithCanonicalMapping
        var cut = text.endIndex
        while let last = expected.last {
            guard cut > text.startIndex else { return nil }
            let index = text.index(before: cut)
            let character = text[index]
            cut = index
            if Self.isSeparator(character) { continue }
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
