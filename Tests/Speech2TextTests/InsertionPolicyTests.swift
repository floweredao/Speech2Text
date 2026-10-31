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

@Test func insertionRequiresExactSafeConditions() {
    #expect(InsertionPolicy.allows(text: "한글 English", trusted: true, sameTarget: true, editable: true))
    #expect(!InsertionPolicy.allows(text: " \n ", trusted: true, sameTarget: true, editable: true))
    #expect(!InsertionPolicy.allows(text: "hello", trusted: false, sameTarget: true, editable: true))
    #expect(!InsertionPolicy.allows(text: "hello", trusted: true, sameTarget: false, editable: true))
    #expect(!InsertionPolicy.allows(text: "hello", trusted: true, sameTarget: true, editable: false))
}
