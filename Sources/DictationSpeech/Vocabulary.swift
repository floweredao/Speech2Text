import Foundation

/// The user's dictionary. Each line is a term to recognize (`센파이`) or a correction (`쏀빠이 → 센파이`).
/// Terms and correction targets go to Soniox as context; corrections also rewrite the recognized text.
public struct Vocabulary: Sendable, Equatable {
    public struct Correction: Sendable, Equatable {
        public let heard: String
        public let written: String
    }

    public let terms: [String]
    public let corrections: [Correction]

    public init(_ text: String = "") {
        var terms: [String] = [], corrections: [Correction] = []
        for line in text.components(separatedBy: .newlines) {
            let parts = Self.split(line)
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                corrections.append(Correction(heard: parts[0], written: parts[1]))
                terms.append(parts[1])
            } else if parts.count == 1, !parts[0].isEmpty {
                terms.append(parts[0])
            }
        }
        var seen = Set<String>()
        self.terms = terms.filter { seen.insert($0).inserted }
        // Longer phrases first, so a correction is never pre-empted by one of its own words.
        self.corrections = corrections.sorted { $0.heard.count > $1.heard.count }
    }

    private static func split(_ line: String) -> [String] {
        for arrow in ["→", "=>", "->"] where line.contains(arrow) {
            return line.components(separatedBy: arrow).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return [line.trimmingCharacters(in: .whitespaces)]
    }

    public func apply(_ text: String) -> String {
        corrections.reduce(text) {
            $0.replacingOccurrences(of: $1.heard, with: $1.written, options: .caseInsensitive)
        }
    }
}
