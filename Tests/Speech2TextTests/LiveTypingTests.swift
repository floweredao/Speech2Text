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

    /// Speech heard while typing was stopped never lands in the field the user comes back to.
    @Test func resumedTypingSkipsTextHeardWhileStopped() {
        #expect(LiveTextEdit.continuation(of: "첫 문장 둘째 문장", after: "첫 문장") == "둘째 문장")
        #expect(LiveTextEdit.continuation(of: "첫 문", after: "첫 문장") == "")
        #expect(LiveTextEdit.continuation(of: "같은 말", after: "같은 말") == "")
        #expect(LiveTextEdit.continuation(of: "hello world", after: "") == "hello world")
        // Regression: the cut fell inside "바다쓰기", so the next field began with the fragment "다쓰기".
        #expect(LiveTextEdit.continuation(of: "격리된 바다쓰기 입력 시험", after: "격리된 바") == "입력 시험")
    }

    @Test func lineBreaksNeverReachTheTarget() {
        #expect(LiveTextEdit.sanitize("첫 줄\n둘째 줄\r\n끝") == "첫 줄 둘째 줄  끝")
    }
}
