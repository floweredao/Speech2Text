import Foundation
import Testing
@testable import DictationSpeech

struct SonioxReducerTests {
    @Test func providerErrorPreservesCodeAndDiagnostic() throws {
        var reducer = SonioxTranscriptReducer()
        #expect(throws: AppError.provider(code: 408, message: "Audio data was not received.")) {
            try reducer.reduce(Data(#"{"error_code":408,"error_message":"Audio data was not received."}"#.utf8))
        }
    }
    @Test func replacesProvisionalText() throws {
        var reducer = SonioxTranscriptReducer()
        _ = try reducer.reduce(Data(#"{"tokens":[{"text":"잘못","is_final":false}]}"#.utf8))
        let events = try reducer.reduce(Data(#"{"tokens":[{"text":"메모 열어","is_final":false}]}"#.utf8))
        let texts = events.compactMap { event -> String? in
            if case .update(let update) = event { return update.text }; return nil
        }
        #expect(texts == ["메모 열어"])
    }
}

extension SonioxReducerTests {
 @Test func orderedBoundariesAndFinished() throws {
  var r = SonioxTranscriptReducer()
  let events = try r.reduce(Data(#"{"tokens":[{"text":"하나","is_final":true},{"text":"<end>","is_final":true},{"text":"둘","is_final":true},{"text":"<fin>","is_final":true}],"finished":true}"#.utf8))
  #expect(events == [.update(.init(turnID: "soniox-0", revision: 1, text: "하나", isFinal: true)), .update(.init(turnID: "soniox-1", revision: 1, text: "둘", isFinal: true)), .finished])
  #expect(try r.reduce(Data(#"{"tokens":[{"text":"stale","is_final":true}],"finished":true}"#.utf8)).isEmpty)
 }
 @Test func finalPrefixAndPartialRevision() throws {
  var r = SonioxTranscriptReducer()
  _ = try r.reduce(Data(#"{"tokens":[{"text":"확정 ","is_final":true},{"text":"오류","is_final":false}]}"#.utf8))
  #expect(try r.reduce(Data(#"{"tokens":[{"text":"수정","is_final":false}]}"#.utf8)) == [.update(.init(turnID: "soniox-0", revision: 2, text: "확정 수정", isFinal: false))])
 }
 @Test func malformedAndErrorFirst() throws {
  var r = SonioxTranscriptReducer()
  #expect(throws: AppError.provider(code: 401, message: "음성 인식 요청이 거절됐습니다.")) { try r.reduce(Data(#"{"error_code":401,"tokens":[{"text":"bad","is_final":true}],"finished":true}"#.utf8)) }
  #expect(throws: AppError.invalidResponse("Soniox schema")) { try r.reduce(Data(#"{"tokens":[{"text":42}]}"#.utf8)) }
  #expect(try r.reduce(Data(#"{"tokens":[{"text":"good","is_final":false}]}"#.utf8)) == [.update(.init(turnID: "soniox-0", revision: 1, text: "good", isFinal: false))])
 }
}

extension SonioxReducerTests {
 @Test func emptyRevisionClearsProvisional() throws {
  var r = SonioxTranscriptReducer()
  _ = try r.reduce(Data(#"{"tokens":[{"text":"open Notes","is_final":false}]}"#.utf8))
  #expect(try r.reduce(Data(#"{"tokens":[]}"#.utf8)) == [.update(.init(turnID: "soniox-0", revision: 2, text: "", isFinal: false))])
 }
}
