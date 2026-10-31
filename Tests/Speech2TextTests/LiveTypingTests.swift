import AppKit
import Testing
@testable import Speech2Text

@Suite struct LiveTextEditTests {
    @Test(arguments: [
        ("", "안녕"),
        ("안녕", "안녕하세요"),
        ("메모 열어", "메모장 열어 줘"),
        ("오늘은 날시가", "오늘은 날씨가 좋네요"),
        ("hello wrld", "hello world"),
        ("지울 문장", ""),
        ("같은 문장", "같은 문장"),
    ])
    func tailEditReproducesTheRevisedTextExactly(old: String, new: String) {
        let edit = LiveTextEdit.between(old, new)
        #expect(old.hasSuffix(edit.removed))
        #expect(String(old.dropLast(edit.removed.count)) + edit.insert == new)
    }

    @Test func extendingTextNeverDeletes() {
        #expect(LiveTextEdit.between("안녕하", "안녕하세요") == LiveTextEdit(removed: "", insert: "세요"))
    }

    @Test func revisionReplacesOnlyTheChangedTail() {
        #expect(LiveTextEdit.between("메모 열어", "메모장 열어") == LiveTextEdit(removed: " 열어", insert: "장 열어"))
        #expect(LiveTextEdit.between("같은 문장", "같은 문장").isEmpty)
    }

    /// Keyboard-mode fields hide their caret, so any key or click the user makes there ends live typing.
    @Test func userKeysAndClicksCountAsEditsButOurOwnEventsAndShortcutsDoNot() {
        #expect(LiveTyper.isUserEdit(type: .keyDown, sourceUserData: 0, isShortcut: false))
        #expect(LiveTyper.isUserEdit(type: .leftMouseDown, sourceUserData: 0, isShortcut: false))
        #expect(!LiveTyper.isUserEdit(type: .keyDown, sourceUserData: LiveTyper.eventMarker, isShortcut: false))
        #expect(!LiveTyper.isUserEdit(type: .keyDown, sourceUserData: 0, isShortcut: true))
        #expect(!LiveTyper.isUserEdit(type: .flagsChanged, sourceUserData: 0, isShortcut: false))
    }

    /// Regression: after the user switched apps mid-dictation, nothing more was typed anywhere.
    @Test func focusChangesAndUserEditsWaitForTheNextFieldButFailuresDoNot() {
        #expect(LiveTyper.Outcome.targetChanged.resumesInNextField)
        #expect(LiveTyper.Outcome.userEdited.resumesInNextField)
        #expect(!LiveTyper.Outcome.failed.resumesInNextField)
        #expect(!LiveTyper.Outcome.applied.resumesInNextField)
    }

    /// Regression: with the Korean input method in a web field, bare backspace keys mangled the revised start
    /// ("어 오오늘은가 …" instead of "오늘은 회의가 …"). Each backspace must carry the backspace character.
    @Test func revisionsSendBackspaceCharactersThenTheNewText() {
        let strokes = LiveTyper.keystrokes(for: LiveTextEdit.between("어 오늘", "오늘은 회의"))
        #expect(strokes == Array(repeating: LiveTyper.Keystroke(key: 51, text: "\u{8}"), count: 4)
            + [LiveTyper.Keystroke(key: 0, text: "오늘은 회의")])
        #expect(LiveTyper.keystrokes(for: LiveTextEdit(removed: "", insert: String(repeating: "가", count: 20)))
            .map(\.text) == [String(repeating: "가", count: 16), String(repeating: "가", count: 4)])
    }

    /// Regression: in a browser address bar, which selects its URL on focus, dictation stopped before typing anything.
    @Test func aSelectionWhereDictationStartsIsTypedOverWithKeys() {
        #expect(LiveTyper.startMode(selectionLength: 43) == .keyboard)
        #expect(LiveTyper.startMode(selectionLength: 0) == .accessibility)
    }

    /// Regression: a character longer than one keystroke's 16 UTF-16 units was preceded by an empty keystroke,
    /// a key event on key code 0 (the A key) that carried no text.
    @Test func aCharacterLongerThanOneKeystrokeIsSentWholeWithoutAnEmptyOne() {
        let accented = "a" + String(repeating: "\u{301}", count: 16)
        #expect(accented.count == 1 && accented.utf16.count == 17)
        #expect(LiveTyper.keystrokes(for: LiveTextEdit(removed: "", insert: accented + "가")).map(\.text) == [accented, "가"])
        #expect(LiveTyper.keystrokes(for: LiveTextEdit(removed: "", insert: "")).isEmpty)
    }

    /// Korean revisions often change only the last syllable (a final consonant arrives, or a vowel is corrected);
    /// exactly that syllable is replaced, with one backspace per character, never per code unit.
    @Test func syllableRevisionsReplaceWholeCharacters() {
        #expect(LiveTextEdit.between("오늘은 회으", "오늘은 회의") == LiveTextEdit(removed: "으", insert: "의"))
        #expect(LiveTextEdit.between("하", "한") == LiveTextEdit(removed: "하", insert: "한"))
        #expect(LiveTextEdit.between("👍", "👍🏽") == LiveTextEdit(removed: "👍", insert: "👍🏽"))
        #expect(LiveTyper.keystrokes(for: LiveTextEdit.between("가나다 👍🏽", "가"))
            == Array(repeating: LiveTyper.Keystroke(key: 51, text: "\u{8}"), count: 4))
    }

    @Test func lineBreaksNeverReachTheTarget() {
        #expect(LiveTextEdit.sanitize("첫 줄\n둘째 줄\r\n끝") == "첫 줄 둘째 줄  끝")
    }
}

@Suite struct TypedReturnTests {
    @Test func onlyAPlainReturnEndsTheDictation() {
        #expect(LiveTyper.isPlainReturn(keyCode: 36, modifiers: []))
        #expect(LiveTyper.isPlainReturn(keyCode: 76, modifiers: [.numericPad]))
        #expect(!LiveTyper.isPlainReturn(keyCode: 36, modifiers: [.shift]))
        #expect(!LiveTyper.isPlainReturn(keyCode: 36, modifiers: [.command]))
        #expect(!LiveTyper.isPlainReturn(keyCode: 0, modifiers: []))
    }
}
