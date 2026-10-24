import Foundation

/// A phrase spoken at the very end of a dictation that presses Return after the text is typed.
/// Spacing, case and punctuation are ignored, since recognition writes "엔터 보내기", "엔터보내기." and so on.
/// The words may also come in another order or be said again ("엔터 보내기. 보내기, 엔터."),
/// because a speaker repeats the command when nothing seems to happen.
/// With a trigger word the command counts only right after it ("<trigger> 엔터 보내기"), and both are left out.
struct SpokenEnter: Equatable {
    /// The default phrase of every UI language. The UI language does not tell which language the speaker uses
    /// (an English macOS shows "send enter" to someone who says "엔터 보내기"), so the default accepts them all.
    static let defaultPhrases = ["엔터 보내기", "send enter"]

    let phrases: [String]
    let trigger: SpokenPhrase?

    init(phrase: String, trigger: SpokenPhrase? = nil) {
        phrases = [phrase]
        self.trigger = trigger
    }

    /// A phrase left at the default shown in Settings counts in every language; a phrase the user typed counts alone.
    init(setting phrase: String, shownDefault: String, trigger: SpokenPhrase? = nil) {
        let isDefault = phrase.trimmingCharacters(in: .whitespacesAndNewlines) == shownDefault
        phrases = isDefault ? [phrase] + Self.defaultPhrases.filter { $0 != phrase } : [phrase]
        self.trigger = trigger
    }

    /// Phrases to send to recognition as context, so they are written the way they are matched.
    var terms: [String] { phrases + (trigger?.terms ?? []) }

    func strip(_ text: String) -> String? {
        phrases.compactMap { phrase in
            Self.strip(text, phrase: phrase).flatMap { before in trigger.map { $0.strippingSuffix(before) } ?? before }
        }.min { $0.count < $1.count }
    }

    private static func strip(_ text: String, phrase: String) -> String? {
        let words = Self.words(in: phrase.precomposedStringWithCanonicalMapping.lowercased())
        guard !words.isEmpty else { return nil }
        let text = text.precomposedStringWithCanonicalMapping
        let tokens = Self.words(in: text)
        var end = tokens.endIndex
        var cut: String.Index?
        // Each pass removes the shortest trailing group of tokens that says every word of the phrase.
        while let start = Self.commandStart(tokens[..<end], words: words) {
            cut = tokens[start].startIndex
            end = start
        }
        guard let cut else { return nil }
        return text[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commandStart(_ tokens: ArraySlice<Substring>, words: [Substring]) -> Int? {
        let needed = Set(words.map { String($0) })
        var said: Set<String> = []
        for index in tokens.indices.reversed() {
            guard let parts = split(tokens[index].lowercased(), into: words) else { return nil }
            said.formUnion(parts)
            if said == needed { return index }
        }
        return nil
    }

    /// The phrase words a token is made of ("엔터보내기" is both), or nil when it holds anything else.
    private static func split(_ token: String, into words: [Substring]) -> Set<String>? {
        let letters = Array(token)
        var reach: [Set<String>?] = Array(repeating: nil, count: letters.count + 1)
        reach[0] = []
        for start in letters.indices {
            guard let before = reach[start] else { continue }
            for word in words {
                let end = start + word.count
                guard end <= letters.count, letters[start..<end].elementsEqual(word) else { continue }
                reach[end] = (reach[end] ?? []).union(before).union([String(word)])
            }
        }
        return reach[letters.count]
    }

    private static func words(in text: String) -> [Substring] {
        text.split(whereSeparator: isSeparator)
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation
    }
}
