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

@Test func insertionRequiresExactSafeConditions() {
    #expect(InsertionPolicy.allows(text: "한글 English", trusted: true, sameTarget: true, editable: true))
    #expect(!InsertionPolicy.allows(text: " \n ", trusted: true, sameTarget: true, editable: true))
    #expect(!InsertionPolicy.allows(text: "hello", trusted: false, sameTarget: true, editable: true))
    #expect(!InsertionPolicy.allows(text: "hello", trusted: true, sameTarget: false, editable: true))
    #expect(!InsertionPolicy.allows(text: "hello", trusted: true, sameTarget: true, editable: false))
}
