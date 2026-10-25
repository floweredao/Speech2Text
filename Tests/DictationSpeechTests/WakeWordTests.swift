import Foundation
import Testing
@testable import DictationSpeech

/// scripts/fetch-wake-model.sh (run by scripts/test.sh) puts the pinned model and its sample recordings here.
private let model = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Vendor/wake-model")

@Suite(.timeLimit(.minutes(1)))
@MainActor struct WakeWordTests {
    /// The pairs the model ships in its own keywords.txt. Its tokenizer is a unigram model; merging pieces greedily
    /// splits most of these differently.
    @Test(arguments: [
        ("HELLO WORLD", "▁HE LL O ▁WORLD"), ("hi google", "▁HI ▁GO O G LE"), ("MERRY CHRISTMAS", "▁ME R RY ▁ CH R IST MA S"),
        ("Light up", "▁ L IGHT ▁UP"), ("LOVELY CHILD", "▁LOVE LY ▁CHI L D"), ("FOREVER", "▁FOR E VER"),
        ("HAPPY  NEW YEAR", "▁HA PP Y ▁NEW ▁YEAR"),
    ])
    func phrasesSplitLikeTheModelsOwnKeywords(phrase: String, pieces: String) throws {
        let tokenizer = try WakePhraseTokenizer(sentencepieceModel: model.appendingPathComponent("bpe.model"))
        #expect(tokenizer.pieces(for: phrase)?.joined(separator: " ") == pieces)
    }

    /// A distant microphone's quiet voice is brought up for the wake engines; loud audio and silence are left alone.
    @Test func quietAudioIsBroughtUpAndLoudAudioIsLeftAlone() {
        func pcm(_ value: Int16) -> Data { [Int16](repeating: value, count: 320).withUnsafeBytes { Data($0) } }
        func peak(_ data: Data) -> Int16 { data.withUnsafeBytes { $0.bindMemory(to: Int16.self).max() ?? 0 } }
        var level = WakeLevel()
        #expect(peak(level.amplify(pcm(80))) == 8_000)
        #expect(peak(level.amplify(pcm(0))) == 0)
        var loud = WakeLevel()
        #expect(loud.amplify(pcm(20_000)) == pcm(20_000))
    }

    @Test func phrasesTheEnglishModelCannotSpellAreRefused() throws {
        let tokenizer = try WakePhraseTokenizer(sentencepieceModel: model.appendingPathComponent("bpe.model"))
        #expect(tokenizer.pieces(for: "헤이 키다모") == nil)
        #expect(tokenizer.pieces(for: "hey 2") == nil)
        #expect(tokenizer.pieces(for: "  ") == nil)
    }

    /// Through the real model and the app's file capture: the phrase spoken in the recording wakes the listener once,
    /// a phrase that is not in it never does, and the end of the audio is reported.
    @Test(arguments: [("LIGHT UP", 1), ("HEY KIDAMO", 0)])
    func theListenerWakesOnlyOnThePhraseInTheRecording(phrase: String, expected: Int) async throws {
        let recording = model.appendingPathComponent("test_wavs/0.wav")
        let listener = try WakeWordListener(model: model) { _ in FileAudioCapture(url: recording, realTime: false) }
        let ended = AsyncStream<String>.makeStream()
        var wakes = 0
        listener.onWake = { wakes += 1 }
        listener.onFailure = { ended.continuation.yield($0) }
        listener.start(pieces: try #require(listener.tokenizer.pieces(for: phrase)), sensitivity: .standard, deviceUID: nil)
        var iterator = ended.stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(wakes == expected)
        #expect(!listener.isListening)
    }
}
