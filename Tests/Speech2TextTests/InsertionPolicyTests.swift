import Testing
@testable import Speech2Text

@Test func webEditorsUseNativeInputEvenWhenAccessibilityAdvertisesAWritableSelection() {
    #expect(!InsertionPolicy.allowsAccessibilityWrite(inWebContent: true, textSettable: true))
    #expect(!InsertionPolicy.allowsAccessibilityWrite(inWebContent: true, textSettable: false))
    #expect(InsertionPolicy.allowsAccessibilityWrite(inWebContent: false, textSettable: true))
    #expect(!InsertionPolicy.allowsAccessibilityWrite(inWebContent: false, textSettable: false))
}

@Test func insertionRequiresExactSafeConditions() {
    #expect(InsertionPolicy.allows(text: "한글 English", trusted: true, sameTarget: true, editable: true))
    #expect(!InsertionPolicy.allows(text: " \n ", trusted: true, sameTarget: true, editable: true))
    #expect(!InsertionPolicy.allows(text: "hello", trusted: false, sameTarget: true, editable: true))
    #expect(!InsertionPolicy.allows(text: "hello", trusted: true, sameTarget: false, editable: true))
    #expect(!InsertionPolicy.allows(text: "hello", trusted: true, sameTarget: true, editable: false))
}
