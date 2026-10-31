import Foundation
import Testing
@testable import Speech2Text

@Suite struct WakeListeningTests {
    /// The wake phrase starts off, an older "on" is turned off once, and the user's later choice is kept.
    @Test func wakeListeningIsOffByDefaultAndOldOnIsTurnedOffOnce() throws {
        let fresh = try #require(UserDefaults(suiteName: "WakeTests-\(UUID().uuidString)"))
        #expect(!AppModel.loadWakeListeningEnabled(fresh))
        let old = try #require(UserDefaults(suiteName: "WakeTests-\(UUID().uuidString)"))
        old.set(true, forKey: "wakeListeningEnabled")
        #expect(!AppModel.loadWakeListeningEnabled(old))
        old.set(true, forKey: "wakeListeningEnabled")
        #expect(AppModel.loadWakeListeningEnabled(old))
    }

    /// The idle microphone listens only when the user turned it on, the phrase can be listened for, and no dictation
    /// is running: dictation must never be started a second time over itself.
    @Test(arguments: [
        (true, true, false, true), (false, true, false, false), (true, false, false, false), (true, true, true, false),
    ])
    func listensOnlyWhenOnUsableAndIdle(enabled: Bool, usable: Bool, busy: Bool, listens: Bool) {
        #expect(AppModel.listensForWake(enabled: enabled, phraseIsUsable: usable, isBusy: busy) == listens)
    }

    /// What macOS's on-device Korean recognizer wrote for "헤이 컴퓨터" and "Hey Computer" in the system's voices wakes the
    /// app; ordinary sentences about a computer do not.
    @Test(arguments: [
        ("에이 컴퓨터 오늘 메일 내용 정리해서 열어 줘.", true), ("제이컴퓨터 오늘 메일", true), ("회의 컴퓨터 오늘", true),
        ("제이 컴부터 오늘", true), ("Hey, computer. Please write", true), ("헤이 컴퓨터", true),
        ("컴퓨터를 새로 사야 할 것 같아.", false), ("이 컴퓨터 좀 봐.", false), ("The computer is on the desk.", false),
        ("Okay computer.", false), ("헤이, 잠깐만 기다려 봐.", false),
    ])
    func theRecognizerWakesOnTheDefaultPhraseAndItsSoundAlikes(text: String, wakes: Bool) {
        #expect(AppModel.wakeMatcher(for: "Hey Computer")(text) == wakes)
    }

    /// A phrase the user chose is matched as written: the default's sound-alikes do not carry over to it.
    @Test func aChosenPhraseIgnoresTheDefaultsSoundAlikes() {
        let matches = AppModel.wakeMatcher(for: "Hey Speech")
        #expect(matches("hey speech, start"))
        #expect(!matches("에이 컴퓨터"))
    }

    /// The wake phrase starts dictation the way a spoken start request does: never toggling a running one off.
    @Test(arguments: [(false, false, DictationRequest.Effect.start), (true, true, .none), (false, true, .none)])
    func theWakePhraseOnlyStarts(recording: Bool, busy: Bool, effect: DictationRequest.Effect) {
        #expect(DictationRequest.start.effect(isRecording: recording, isBusy: busy) == effect)
    }
}
