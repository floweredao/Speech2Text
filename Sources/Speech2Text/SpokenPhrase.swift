import Foundation

/// A phrase as it appears in recognized text. Case, spacing and punctuation are ignored, because recognition writes
/// "Hey Kidamo", "hey, kidamo" or "헤이키다모" for the same speech. Used for the trigger word said before a voice
/// command and for the wake phrase that finishes a dictation. See DESIGN.md, "말로 고치기".
struct SpokenPhrase: Equatable {
    /// Letters only, lowercased: one entry per accepted spelling.
    private let spellings: [[Character]]
    /// The phrase and its other spellings, for recognition context.
    let terms: [String]

    init(_ phrase: String, alternates: [String] = []) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        terms = trimmed.isEmpty ? [] : [trimmed] + alternates
        spellings = terms.map(Self.letters).filter { !$0.isEmpty }
    }

    var isEmpty: Bool { spellings.isEmpty }

    /// Splits `text` at the first wake phrase that starts a word: the words before it and those after it.
    func split(_ text: String) -> (before: String, after: String)? {
        let characters = Array(text)
        for start in characters.indices where Self.startsWord(characters, at: start) {
            guard let end = matchEnd(characters, from: start) else { continue }
            return (Self.before(characters[..<start]), Self.after(characters[end...]))
        }
        return nil
    }

    /// The text before a wake phrase that ends it, or nil when it does not end with one.
    func strippingSuffix(_ text: String) -> String? {
        let characters = Array(text)
        for start in characters.indices where Self.startsWord(characters, at: start) {
            guard let end = matchEnd(characters, from: start),
                  characters[end...].allSatisfy({ !Self.isLetter($0) }) else { continue }
            return Self.before(characters[..<start])
        }
        return nil
    }

    /// Where a trailing beginning of the wake phrase starts ("… 헤이 키다"), so live typing can wait for the rest.
    func partialSuffixStart(_ text: String) -> String.Index? {
        let characters = Array(text)
        for start in characters.indices where Self.startsWord(characters, at: start) {
            let tail = Self.letters(String(characters[start...]))
            guard tail.count >= 2, spellings.contains(where: { $0.count > tail.count && $0.starts(with: tail) }) else {
                continue
            }
            return text.index(text.startIndex, offsetBy: start)
        }
        return nil
    }

    private func matchEnd(_ characters: [Character], from start: Int) -> Int? {
        spellings.compactMap { spelling -> Int? in
            var index = start, matched = 0
            while matched < spelling.count, index < characters.count {
                let character = characters[index]
                if Self.isLetter(character) {
                    guard Self.folded(character) == spelling[matched] else { return nil }
                    matched += 1
                }
                index += 1
            }
            return matched == spelling.count ? index : nil
        }.max()
    }

    private static func letters(_ text: String) -> [Character] {
        text.precomposedStringWithCanonicalMapping.filter(isLetter).map(folded)
    }

    private static func isLetter(_ character: Character) -> Bool { character.isLetter || character.isNumber }
    private static func folded(_ character: Character) -> Character { Character(character.lowercased()) }

    private static func startsWord(_ characters: [Character], at index: Int) -> Bool {
        isLetter(characters[index]) && (index == 0 || !isLetter(characters[index - 1]))
    }

    /// The dictated words before the phrase keep their sentence punctuation; only a comma that led into it goes.
    private static func before(_ characters: ArraySlice<Character>) -> String {
        var text = String(characters)
        while let last = text.last, last.isWhitespace || last == "," || last == "，" { text.removeLast() }
        return text
    }

    private static func after(_ characters: ArraySlice<Character>) -> String {
        String(characters).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
