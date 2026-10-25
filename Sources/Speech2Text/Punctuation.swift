import Foundation

/// How much of Soniox's punctuation reaches the field. Only the typed text changes: voice commands are still
/// recognized from the words as heard.
enum PunctuationStyle: String, CaseIterable, Sendable {
    /// Everything as recognized.
    case asIs
    /// Commas go; sentence-ending marks (. ? !) stay.
    case noCommas
    /// Commas and sentence-ending marks all go.
    case none

    /// A comma said by name ("쉼표"). It stands apart from Soniox's commas until the text is typed, so even
    /// "no commas" keeps it: the speaker asked for it.
    static let spokenComma: Character = "\u{E000}"

    private static let commas: Set<Character> = [",", "，", "、"]
    private static let endMarks: Set<Character> = [".", "?", "!", "。", "？", "！"]

    func apply(_ text: String) -> String {
        let spoken = String(Self.spokenComma)
        guard self != .asIs else { return text.replacingOccurrences(of: spoken, with: ",") }
        let chars = Array(text)
        var out = ""
        for (i, char) in chars.enumerated() {
            let before = i > 0 ? chars[i - 1] : nil
            let after = i + 1 < chars.count ? chars[i + 1] : nil
            if drops(char, between: before, and: after) {
                // "a , b" would leave two spaces.
                if out.last == " ", after == " " { out.removeLast() }
                continue
            }
            out.append(char)
        }
        return out.replacingOccurrences(of: spoken, with: ",")
    }

    /// A comma between digits (1,000) and a period inside a word or number (3.14, example.com) are not punctuation.
    private func drops(_ char: Character, between before: Character?, and after: Character?) -> Bool {
        if char == "," { return !(before?.isNumber == true && after?.isNumber == true) }
        if Self.commas.contains(char) { return true }
        guard self == .none, Self.endMarks.contains(char) else { return false }
        if char == ".", let before, let after, before.isLetter || before.isNumber, after.isLetter || after.isNumber {
            return false
        }
        return true
    }
}
