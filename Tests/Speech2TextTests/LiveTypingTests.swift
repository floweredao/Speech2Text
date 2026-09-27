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

    @Test func lineBreaksNeverReachTheTarget() {
        #expect(LiveTextEdit.sanitize("첫 줄\n둘째 줄\r\n끝") == "첫 줄 둘째 줄  끝")
    }
}
