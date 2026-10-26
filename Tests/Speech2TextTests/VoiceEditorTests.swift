import DictationSpeech
import Foundation
import Testing
@testable import Speech2Text

private func final(_ text: String) -> SpokenTurn { SpokenTurn(text: text, isFinal: true) }
private func live(_ text: String) -> SpokenTurn { SpokenTurn(text: text, isFinal: false) }

@Suite struct VoiceEditorTests {
    @Test(arguments: [
        ("지워", VoiceCommand.deleteLastSentence), ("지워 줘.", .deleteLastSentence), ("마지막 문장 지워주세요", .deleteLastSentence),
        ("Delete that.", .deleteLastSentence), ("방금 말한 거 지워.", .deleteLastSentence), ("방금 한 말 지워 줘", .deleteLastSentence),
        ("한 단어 지워", .deleteLastWord), ("다 지워!", .clearAll),
        ("되돌려 줘", .undo), ("Undo", .undo), ("회의를 미팅으로 바꿔 줘", .replace("회의", "미팅")),
        ("세 시를 네 시로 바꿔", .replace("세 시", "네 시")), ("replace Monday with Tuesday", .replace("Monday", "Tuesday")),
    ])
    func commandsAreRecognizedWhateverTheSpacingOrPoliteEnding(utterance: String, command: VoiceCommand) {
        #expect(VoiceCommand.parse(utterance) == command)
    }

    @Test func ordinarySentencesAreNotCommands() {
        #expect(VoiceCommand.parse("이 파일은 지워도 돼요") == nil)
        #expect(VoiceCommand.parse("내일 다시 연락드릴게요.") == nil)
        #expect(VoiceCommand.parse("") == nil)
    }

    /// Every command is performed here as if Jev called it one; what Jev answers is `JevGateTests`.
    @Test func deleteReplaceAndUndoEditOnlyTheDictatedText() {
        let turns = [final("첫 문장입니다."), final("둘째 문장이에요."), final("지워"), final("회의는 세 시예요."),
                     final("세 시를 네 시로 바꿔"), final("되돌려")]
        let result = apply(turns)
        #expect(result.text == "첫 문장입니다. 회의는 세 시예요.")
        #expect(result.outcomes == [.applied(.deleteLastSentence), .applied(.replace("세 시", "네 시")), .applied(.undo)])
    }

    @Test(arguments: [("세 시 지워", "세 시"), ("'급히'를 지워 주세요.", "급히"), ("회의 자료 빼 줘", "회의 자료"),
                      ("delete Monday", "Monday")])
    func aNamedPartCanBeDeleted(utterance: String, target: String) {
        #expect(VoiceCommand.parse(utterance) == .delete(target))
    }

    /// Only the last place the words were said goes, found whatever the recognizer did with the spaces, and the
    /// sentence around it closes up. Words that were never said are no edit and are typed.
    @Test func deletingANamedPartRemovesOnlyItsLastOccurrence() {
        let result = apply([final("세 시에 봐요. 회의는 급히 세시예요."), final("급히 지워"), final("세 시를 지워"),
                            final("사과 지워")])
        #expect(result.text == "세 시에 봐요. 회의는 예요. 사과 지워")
        #expect(result.outcomes == [.applied(.delete("급히")), .applied(.delete("세 시"))])
    }

    @Test func turnedOffEverythingIsTyped() {
        let result = VoiceEditor.apply([final("안녕하세요."), final("지워")], gate: .off)
        #expect(result.text == "안녕하세요. 지워")
        #expect(result.outcomes.isEmpty)
    }

    @Test func everyCommandBelongsToOneAction() {
        #expect(VoiceCommand.deleteLastWord.action == .delete)
        #expect(VoiceCommand.delete("A").action == .delete)
        #expect(VoiceCommand.clearAll.action == .clearAll)
        #expect(VoiceCommand.replace("A", "B").action == .replace)
        #expect(VoiceCommand.undo.action == .undo)
        #expect(VoiceCommand.mark("?").action == .mark)
        #expect(!VoiceAction.edits.contains(.enter))
    }

    /// A command of an action that is off is typed as said, never held back and never sent to Jev.
    @Test(arguments: [
        (VoiceAction.delete, "지워"), (.clearAll, "다 지워"), (.replace, "세 시를 네 시로 바꿔"), (.mark, "물음표"),
    ])
    func aCommandWhoseActionIsOffIsTypedWithoutAsking(action: VoiceAction, utterance: String) {
        let turns = [final("회의는 세 시예요."), final(utterance)]
        let on = VoiceEditor.apply(turns, gate: .judged([:]))
        #expect(on.question != nil || !on.outcomes.isEmpty)
        let off = VoiceEditor.apply(turns, gate: .judged([:], actions: VoiceAction.edits.subtracting([action])))
        #expect(off.text == "회의는 세 시예요. " + utterance)
        #expect(off.question == nil)
        #expect(off.outcomes.isEmpty)
        #expect(VoiceEditor.apply([final("회의는 세 시예요."), live(utterance)],
                                  gate: .judged([:], actions: VoiceAction.edits.subtracting([action]))).text
                == "회의는 세 시예요. " + utterance)
    }

    @Test func undoOffKeepsATakenBackEditAsWords() {
        let turns = [final("좋아요."), final("지워. 되돌려")]
        #expect(VoiceEditor.apply(turns, gate: .judged([:])).text == "좋아요.")
        let result = VoiceEditor.apply(turns, gate: .judged([:], unanswered: .command,
                                                            actions: VoiceAction.edits.subtracting([.undo])))
        #expect(result.text == "좋아요. 지워. 되돌려")
        #expect(result.outcomes.isEmpty)
    }

    @Test func actionsTurnedOffAreStoredAndNewOnesStartOn() throws {
        let defaults = try #require(UserDefaults(suiteName: "VoiceActionTests"))
        defaults.removePersistentDomain(forName: "VoiceActionTests")
        #expect(VoiceAction.load(defaults) == VoiceAction.edits)
        VoiceAction.store(VoiceAction.edits.subtracting([.mark, .undo]), defaults)
        #expect(defaults.stringArray(forKey: "voiceActionsOff") == ["mark", "undo"])
        defaults.set(["mark", "undo", "retired"], forKey: "voiceActionsOff")
        #expect(VoiceAction.load(defaults) == [.delete, .clearAll, .replace])
        VoiceAction.store(VoiceAction.edits, defaults)
        #expect(defaults.object(forKey: "voiceActionsOff") == nil)
    }

    /// The trigger word mode is gone: whoever chose it gets Jev, and an old \"voice editing off\" stays off.
    @Test func theStoredJudgeChoiceMovesFromTheTriggerWordToJev() throws {
        let defaults = try #require(UserDefaults(suiteName: "CommandJudgeModeTests"))
        defaults.removePersistentDomain(forName: "CommandJudgeModeTests")
        #expect(CommandJudgeMode.load(defaults) == .jev)
        defaults.set(false, forKey: "voiceEditingEnabled")
        #expect(CommandJudgeMode.load(defaults) == .off)
        defaults.set("trigger", forKey: "commandJudge")
        #expect(CommandJudgeMode.load(defaults) == .jev)
        defaults.set("off", forKey: "commandJudge")
        #expect(CommandJudgeMode.load(defaults) == .off)
        defaults.set("jev", forKey: "commandJudge")
        #expect(CommandJudgeMode.load(defaults) == .jev)
    }
}

private func apply(_ turns: [SpokenTurn]) -> VoiceEditor.Result {
    VoiceEditor.apply(turns, gate: .judged([:], unanswered: .command))
}
