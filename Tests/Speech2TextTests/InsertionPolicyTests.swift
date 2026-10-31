import AppKit
import Testing
@testable import Speech2Text

@Test func webEditorsUseNativeInputEvenWhenAccessibilityAdvertisesAWritableSelection() {
    #expect(!InsertionPolicy.allowsAccessibilityWrite(inWebContent: true, textSettable: true))
    #expect(!InsertionPolicy.allowsAccessibilityWrite(inWebContent: true, textSettable: false))
    #expect(InsertionPolicy.allowsAccessibilityWrite(inWebContent: false, textSettable: true))
    #expect(!InsertionPolicy.allowsAccessibilityWrite(inWebContent: false, textSettable: false))
}

/// Discord with its accessibility tree switched off reports no focused field until it is asked to turn it on.
@Test @MainActor func aFailedFocusLookupWakesTheAppSoTheNextLookupFindsTheField() {
    var treeOn = false
    var wakes = 0
    let lookup = { treeOn ? "message box" : nil }
    let wake = { wakes += 1; treeOn = true }
    #expect(TextInsertion.focusedElement(lookup: lookup, wake: wake) == nil)
    #expect(TextInsertion.focusedElement(lookup: lookup, wake: wake) == "message box")
    #expect(wakes == 1)
}

/// The overlay's Paste and the paste shortcut send what live typing sends: one line, so a terminal never runs it.
@Test func manualInsertionSendsTheLiveTypingSingleLinePayload() {
    let transcript = "list files\nrm -rf tmp\r\nls"
    #expect(InsertionPolicy.payload(transcript) == LiveTextEdit.sanitize(transcript))
    #expect(InsertionPolicy.payload("list files\nrm -rf tmp") == "list files rm -rf tmp")
    #expect(InsertionPolicy.payload("a\u{2028}b\rc") == "a b c")
}

/// The automatic paste leaves the dictation on the pasteboard, so it is marked for clipboard managers and Universal
/// Clipboard to skip. A Copy the user pressed is their own action and stays a plain copy.
@Test @MainActor func onlyTheAutomaticPasteMarksItsPasteboardWriteAsTransient() throws {
    let board = NSPasteboard(name: .init("Speech2TextTests-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let insertion = TextInsertion()

    #expect(insertion.copy("한글 one line", to: board, transient: true))
    #expect(board.string(forType: .string) == "한글 one line")
    #expect(TextInsertion.transientPasteTypes.allSatisfy { board.types?.contains($0) == true })

    #expect(insertion.copy("한글 one line", to: board))
    #expect(board.string(forType: .string) == "한글 one line")
    #expect(TextInsertion.transientPasteTypes.allSatisfy { board.types?.contains($0) == false })

    #expect(!insertion.copy("", to: board, transient: true))
}

@Test func insertionRequiresExactSafeConditions() {
    #expect(InsertionPolicy.allows(text: "한글 English", trusted: true, sameTarget: true, editable: true))
    #expect(!InsertionPolicy.allows(text: " \n ", trusted: true, sameTarget: true, editable: true))
    #expect(!InsertionPolicy.allows(text: "hello", trusted: false, sameTarget: true, editable: true))
    #expect(!InsertionPolicy.allows(text: "hello", trusted: true, sameTarget: false, editable: true))
    #expect(!InsertionPolicy.allows(text: "hello", trusted: true, sameTarget: true, editable: false))
}
