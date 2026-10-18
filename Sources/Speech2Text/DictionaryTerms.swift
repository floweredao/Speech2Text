import Foundation

enum DictionaryTerms {
    static let standard = ["OMO", "ULW", "센파이"]

    static func adding(_ input: String, to terms: [String]) -> [String] {
        var result = terms
        for word in input.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let term = word.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { continue }
            result.append(term)
        }
        return result
    }

    /// 1.3.0 stored the dictionary as lines, some written as "heard → written"; only the written word survives.
    static func migrating(lines: String) -> [String] {
        let written = lines.components(separatedBy: .newlines)
            .map { $0.components(separatedBy: CharacterSet(charactersIn: "→>")).last ?? "" }
        return adding(written.joined(separator: "\n"), to: [])
    }
}
