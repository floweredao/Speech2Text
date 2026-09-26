import Carbon.HIToolbox
import Foundation
import Testing
@testable import Speech2Text

@Suite struct ShortcutTests {
    private let bothShifts = ShortcutTrigger.modifiers([.leftShift, .rightShift])
    private let rightCommand = ShortcutTrigger.modifiers([.rightCommand])
    private let controlOptionD = ShortcutTrigger.key(KeyChord(keyCode: UInt16(kVK_ANSI_D), modifiers: [.control, .option]))

    @Test func sideBitsTellLeftAndRightApart() {
        #expect(ModifierKey.held(inRawFlags: (1 << 17) | 0x2 | 0x4) == [.leftShift, .rightShift])
        #expect(ModifierKey.held(inRawFlags: (1 << 20) | 0x10) == [.rightCommand])
        #expect(ModifierKey.held(inRawFlags: (1 << 19) | 0x40 | (1 << 20) | 0x8) == [.rightOption, .leftCommand])
        #expect(ModifierKey.held(inRawFlags: 0) == [])
    }

    @Test func genericFlagWithoutSideBitCountsAsLeft() {
        #expect(ModifierKey.held(inRawFlags: 1 << 18) == [.leftControl])
        #expect(ModifierKey.held(inRawFlags: 1 << 23) == [.function])
    }

    @Test func quickModifierTapReportsEveryKeyThatWasDown() {
        var detector = ModifierTapDetector()
        #expect(detector.update(held: [.leftShift], at: 0) == nil)
        #expect(detector.update(held: [.leftShift, .rightShift], at: 0.05) == nil)
        #expect(detector.update(held: [.rightShift], at: 0.12) == nil)
        #expect(detector.update(held: [], at: 0.15) == [.leftShift, .rightShift])
    }

    @Test func modifiersUsedWithAKeyOrHeldLongAreNotTaps() {
        var detector = ModifierTapDetector()
        _ = detector.update(held: [.leftCommand], at: 0)
        detector.otherInput()
        #expect(detector.update(held: [], at: 0.1) == nil)
        _ = detector.update(held: [.rightCommand], at: 1)
        #expect(detector.update(held: [], at: 1 + ModifierTapDetector.maxHold + 0.1) == nil)
        detector.otherInput()
        _ = detector.update(held: [.rightCommand], at: 3)
        #expect(detector.update(held: [], at: 3.1) == [.rightCommand])
    }

    @Test func singleBindingRunsOnFirstPress() {
        var recognizer = TapSequenceRecognizer(bindings: [Shortcut(trigger: controlOptionD, taps: 1): .toggleDictation])
        #expect(recognizer.press(controlOptionD, at: 0) == [.toggleDictation])
        #expect(recognizer.deadline == nil)
        #expect(recognizer.press(controlOptionD, at: 0.1) == [.toggleDictation])
    }

    @Test func tripleTapRunsOnlyOnTheThirdPressInTime() {
        var recognizer = TapSequenceRecognizer(bindings: [Shortcut(trigger: bothShifts, taps: 3): .toggleDictation])
        #expect(recognizer.press(bothShifts, at: 0) == [])
        #expect(recognizer.press(bothShifts, at: 0.3) == [])
        #expect(recognizer.press(bothShifts, at: 0.6) == [.toggleDictation])
        #expect(recognizer.press(bothShifts, at: 1.0) == [])
        #expect(recognizer.press(bothShifts, at: 1.0 + TapSequenceRecognizer.interval + 0.1) == [])
    }

    @Test func singleWaitsWhenDoubleOfTheSameTriggerIsBound() {
        var recognizer = TapSequenceRecognizer(bindings: [
            Shortcut(trigger: rightCommand, taps: 1): .pasteTranscript,
            Shortcut(trigger: rightCommand, taps: 2): .toggleDictation,
        ])
        #expect(recognizer.press(rightCommand, at: 0) == [])
        #expect(recognizer.deadline == TapSequenceRecognizer.interval)
        #expect(recognizer.press(rightCommand, at: 0.2) == [.toggleDictation])
        #expect(recognizer.deadline == nil)

        #expect(recognizer.press(rightCommand, at: 2) == [])
        #expect(recognizer.expire(at: 2.1) == [])
        #expect(recognizer.expire(at: 2 + TapSequenceRecognizer.interval) == [.pasteTranscript])
        #expect(recognizer.expire(at: 5) == [])
    }

    @Test func anotherTriggerOrTypingEndsAWaitingSequence() {
        var recognizer = TapSequenceRecognizer(bindings: [
            Shortcut(trigger: rightCommand, taps: 1): .pasteTranscript,
            Shortcut(trigger: rightCommand, taps: 2): .toggleDictation,
            Shortcut(trigger: bothShifts, taps: 1): .toggleDictation,
        ])
        _ = recognizer.press(rightCommand, at: 0)
        #expect(recognizer.press(bothShifts, at: 0.1) == [.pasteTranscript, .toggleDictation])
        _ = recognizer.press(rightCommand, at: 1)
        #expect(recognizer.interrupt() == [.pasteTranscript])
        #expect(recognizer.press(rightCommand, at: 1.1) == [])
    }

    @Test func chordsMustNotSwallowTyping() {
        #expect(!KeyChord(keyCode: UInt16(kVK_ANSI_A), modifiers: []).isAllowed)
        #expect(!KeyChord(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift]).isAllowed)
        #expect(KeyChord(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .shift]).isAllowed)
        #expect(KeyChord(keyCode: UInt16(kVK_F5), modifiers: []).isAllowed)
    }

    @Test func settingsRoundTripIncludingClearedShortcut() throws {
        let defaults = try #require(UserDefaults(suiteName: "ShortcutTests-\(UUID().uuidString)"))
        #expect(ShortcutSettings.load(from: defaults) == .standard)
        var settings = ShortcutSettings.standard
        settings[.toggleDictation] = Shortcut(trigger: bothShifts, taps: 2)
        settings[.pasteTranscript] = nil
        settings.save(to: defaults)
        #expect(ShortcutSettings.load(from: defaults) == settings)
    }

    @Test func sameShortcutOnAnotherActionIsReported() {
        let settings = ShortcutSettings.standard
        let toggle = settings[.toggleDictation]!
        #expect(settings.action(using: toggle, except: .pasteTranscript) == .toggleDictation)
        #expect(settings.action(using: toggle, except: .toggleDictation) == nil)
        #expect(settings.action(using: Shortcut(trigger: toggle.trigger, taps: 2), except: .pasteTranscript) == nil)
    }
}
