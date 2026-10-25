import DictationSpeech
import Foundation

/// Diagnostic (`--edit-corpus cases.json [--jev-key-file f]`): runs written turns through the same VoiceEditor and Jev
/// path a dictation takes, without audio, and prints one JSON line per case. Measures how often edits said in many ways
/// are carried out and how often dictated words are taken for edits.
enum EditCorpus {
    struct Case: Decodable { let id: String; let turns: [String] }
    struct Line: Encodable {
        let id: String
        let text: String
        let edits: Int
        let asked: Int
        let jevMs: [Int]
        let tokens: Int
        let failures: [String]
    }

    static func run(file: String, key: String?) async {
        guard let data = FileManager.default.contents(atPath: file),
              let cases = try? JSONDecoder().decode([Case].self, from: data) else {
            print("EDIT_CORPUS_BAD_FILE")
            return
        }
        let judge = JevJudge(timeout: .seconds(5))
        let encoder = JSONEncoder()
        try? await withThrowingTaskGroup(of: Line.self) { group in
            var next = cases.makeIterator(), running = 0
            func add() { if let item = next.next() { group.addTask { await one(item, judge: judge, key: key) }; running += 1 } }
            for _ in 0..<8 { add() }
            while running > 0, let line = try await group.next() {
                running -= 1
                if let json = try? encoder.encode(line) { print(String(decoding: json, as: UTF8.self)) }
                add()
            }
        }
        print("EDIT_CORPUS_DONE")
    }

    private static func one(_ item: Case, judge: JevJudge, key: String?) async -> Line {
        let turns = item.turns.enumerated().map { SpokenTurn(text: $1, isFinal: true, pauseBeforeMs: $0 == 0 ? nil : 1500) }
        var verdicts: [String: CommandVerdict] = [:]
        var ms: [Int] = [], tokens = 0, failures: [String] = []
        while true {
            let result = VoiceEditor.apply(turns, gate: .judged(verdicts))
            guard let question = result.question else {
                let edits = result.outcomes.filter { if case .applied = $0 { true } else { false } }.count
                return Line(id: item.id, text: result.text, edits: edits, asked: ms.count, jevMs: ms, tokens: tokens,
                            failures: failures)
            }
            let answer = await judge.judge(question, key: key)
            verdicts[question.key] = answer.verdict
            ms.append(answer.milliseconds)
            tokens += answer.inputTokens
            if let failure = answer.failure { failures.append(failure) }
        }
    }
}
