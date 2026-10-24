import DictationSpeech
import Foundation
import Testing
@testable import Speech2Text

private func final(_ text: String) -> SpokenTurn { SpokenTurn(text: text, isFinal: true) }
private func live(_ text: String) -> SpokenTurn { SpokenTurn(text: text, isFinal: false) }
private func judged(_ turns: [SpokenTurn], _ verdicts: [String: CommandVerdict] = [:]) -> VoiceEditor.Result {
    VoiceEditor.apply(turns, gate: .judged(verdicts))
}
private func key(_ text: String) -> String { VoiceEditor.questionKey(final(text)) }

@Suite struct JevGateTests {
    @Test func aCommandWaitsForJevAndHoldsBackItAndEverythingAfterIt() {
        let result = judged([final("오늘 회의는 세 시예요."), final("지워."), final("내일 봬요.")])
        #expect(result.text == "오늘 회의는 세 시예요.")
        #expect(result.question == CommandQuestion(key: key("지워."), textBefore: "오늘 회의는 세 시예요.", utterance: "지워.",
                                                   joint: .ownChunk, effect: "delete the last sentence of the dictated text"))
        #expect(result.outcomes.isEmpty)
    }

    @Test func jevDecidesBetweenAnEditAndTypedWords() {
        let turns = [final("첫 문장입니다."), final("둘째 문장이에요."), final("지워.")]
        let edit = judged(turns, [key("지워."): .command])
        #expect(edit.text == "첫 문장입니다.")
        #expect(edit.outcomes == [.applied(.deleteLastSentence)])
        #expect(edit.question == nil)
        let words = judged(turns, [key("지워."): .text])
        #expect(words.text == "첫 문장입니다. 둘째 문장이에요. 지워.")
        #expect(words.outcomes.isEmpty)
    }

    /// A wrong edit is always revertible: "되돌려" right after an edit undoes it without asking Jev.
    @Test func undoRightAfterAnEditIsTakenWithoutAsking() {
        let result = judged([final("첫 문장입니다."), final("둘째 문장이에요."), final("지워."), final("되돌려.")],
                            [key("지워."): .command])
        #expect(result.text == "첫 문장입니다. 둘째 문장이에요.")
        #expect(result.outcomes == [.applied(.deleteLastSentence), .applied(.undo)])
        #expect(result.question == nil)
    }

    @Test func editsThatCannotApplyAreTypedWithoutAsking() {
        let start = judged([final("지워 줘.")])
        #expect(start.text == "지워 줘.")
        #expect(start.question == nil)
        let missing = judged([final("작업 하나 부탁할게."), final("로그인 버튼 색을 파란색으로 바꿔.")])
        #expect(missing.text == "작업 하나 부탁할게. 로그인 버튼 색을 파란색으로 바꿔.")
        #expect(missing.question == nil)
        let noUndo = judged([final("방금 커밋한 거 문제 있어."), final("되돌려.")])
        #expect(noUndo.text == "방금 커밋한 거 문제 있어. 되돌려.")
        #expect(noUndo.question == nil)
    }

    @Test func theCommandMayEndTheSameChunk() {
        let sentence = judged([final("하나. 둘. 지워.")])
        #expect(sentence.text == "하나. 둘.")
        #expect(sentence.question?.joint == .afterSentence)
        #expect(sentence.question?.textBefore == "하나. 둘.")
        let comma = judged([final("그 테스트 파일은 이제 필요 없으니까, 지워.")])
        #expect(comma.text == "그 테스트 파일은 이제 필요 없으니까")
        #expect(comma.question?.joint == .afterComma)
        let edited = judged([final("하나. 둘. 지워.")], [key("하나. 둘. 지워."): .command])
        #expect(edited.text == "하나.")
    }

    @Test func aCommandStillBeingSaidIsHeldBackWithoutAsking() {
        let result = judged([final("안녕하세요."), live("지워")])
        #expect(result.text == "안녕하세요.")
        #expect(result.question == nil)
        #expect(judged([final("안녕하세요."), live("내일 봬요")]).text == "안녕하세요. 내일 봬요")
    }

    @Test func unansweredTurnsCanBeSettledAsText() {
        let result = VoiceEditor.apply([final("오늘 회의는 세 시예요."), final("지워.")], gate: .judged([:], unanswered: .text))
        #expect(result.text == "오늘 회의는 세 시예요. 지워.")
        #expect(result.question == nil)
    }

    @Test func turnsWithoutACommandAreTypedAtOnce() {
        let result = judged([final("이 파일은 지워도 돼요."), live("내일 다시")])
        #expect(result.text == "이 파일은 지워도 돼요. 내일 다시")
        #expect(result.question == nil)
    }
}

private actor Calls {
    var count = 0
    func add() { count += 1 }
}

private func reply(_ status: Int, _ json: String) -> JevJudge.Send {
    { request in
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let question = CommandQuestion(key: "k", textBefore: String(repeating: "가", count: 450) + " 끝.", utterance: "지워.",
                                       joint: .ownChunk, effect: "delete the last sentence of the dictated text")

@Suite struct JevJudgeTests {
    @Test func theRequestSendsOnlyTheUtteranceAndRecentTextWithTheKeyInTheHeader() throws {
        let request = try JevJudge.request(for: question, key: "secret")
        #expect(request.url == JevJudge.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "jev-1.14.0")
        let state = try #require(body["state"] as? [String: Any])
        #expect(state["utterance"] as? String == "지워.")
        #expect((state["text_before"] as? String)?.count == JevJudge.contextLimit)
        #expect((state["text_before"] as? String)?.hasSuffix(" 끝.") == true)
        let criteria = try #require(((body["questions"] as? [String: Any])?["q"] as? [String: Any])?["criteria"] as? [String: String])
        #expect(Set(criteria.keys) == ["COMMAND", "TEXT"])
    }

    @Test func onlyAConfidentCommandIsACommand() async {
        let sure = JevJudge(send: reply(200, #"{"answers":{"q":{"choice":"COMMAND","probabilities":{"COMMAND":0.9,"TEXT":0.1}}},"usage":{"input_tokens":812}}"#))
        let answer = await sure.judge(question, key: "k")
        #expect(answer.verdict == .command)
        #expect(answer.inputTokens == 812)
        #expect(answer.failure == nil)
        let unsure = JevJudge(send: reply(200, #"{"answers":{"q":{"choice":"COMMAND","probabilities":{"COMMAND":0.6,"TEXT":0.4}}}}"#))
        #expect(await unsure.judge(question, key: "k").verdict == .text)
    }

    @Test func failuresTypeTheWords() async {
        let refused = await JevJudge(send: reply(401, "{}")).judge(question, key: "bad")
        #expect(refused.verdict == .text)
        #expect(refused.failure == "HTTP 401")
        let garbled = await JevJudge(send: reply(200, "not json")).judge(question, key: "k")
        #expect(garbled.verdict == .text)
        #expect(garbled.failure != nil)
    }

    @Test func withoutAKeyJevIsNotCalled() async {
        let calls = Calls()
        let judge = JevJudge(send: { request in
            await calls.add()
            return (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        })
        let answer = await judge.judge(question, key: "  ")
        #expect(answer.verdict == .text)
        #expect(answer.failure == "no key")
        #expect(await calls.count == 0)
    }

    /// Time is the behavior here: a slow answer must not hold the words back past the limit.
    @Test func aSlowAnswerTypesTheWordsAtTheLimit() async {
        let judge = JevJudge(timeout: .milliseconds(200), send: { request in
            try await Task.sleep(for: .seconds(10))
            return (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        })
        let answer = await judge.judge(question, key: "k")
        #expect(answer.verdict == .text)
        #expect(answer.failure == "timeout")
        #expect(answer.milliseconds < 2000)
    }
}

@Suite struct CommandCandidateTests {
    @Test func onlyAChunkEndingInACommandIsACandidate() {
        #expect(CommandCandidate("지워 줘.")?.command == .deleteLastSentence)
        #expect(CommandCandidate("회의는 세 시예요. 세 시를 네 시로 바꿔.")?.command == .replace("세 시", "네 시"))
        #expect(CommandCandidate("Scratch that.")?.joint == .ownChunk)
        #expect(CommandCandidate("이 파일은 지워도 돼요.") == nil)
        #expect(CommandCandidate("지워. 그리고 내일 봬요.") == nil)
        #expect(CommandCandidate("") == nil)
    }
}
