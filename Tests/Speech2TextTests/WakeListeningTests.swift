import Testing
@testable import Speech2Text

@Suite struct WakeListeningTests {
    /// The idle microphone listens only when the user turned it on, the phrase can be listened for, and no dictation
    /// is running: dictation must never be started a second time over itself.
    @Test(arguments: [
        (true, true, false, true), (false, true, false, false), (true, false, false, false), (true, true, true, false),
    ])
    func listensOnlyWhenOnUsableAndIdle(enabled: Bool, usable: Bool, busy: Bool, listens: Bool) {
        #expect(AppModel.listensForWake(enabled: enabled, phraseIsUsable: usable, isBusy: busy) == listens)
    }

    /// The wake phrase starts dictation the way a spoken start request does: never toggling a running one off.
    @Test(arguments: [(false, false, DictationRequest.Effect.start), (true, true, .none), (false, true, .none)])
    func theWakePhraseOnlyStarts(recording: Bool, busy: Bool, effect: DictationRequest.Effect) {
        #expect(DictationRequest.start.effect(isRecording: recording, isBusy: busy) == effect)
    }
}
