import AppKit
import ApplicationServices

struct LiveTextEdit: Equatable {
    let removed: String
    let insert: String

    var isEmpty: Bool { removed.isEmpty && insert.isEmpty }

    static func between(_ old: String, _ new: String) -> LiveTextEdit {
        var left = old.startIndex, right = new.startIndex
        while left != old.endIndex, right != new.endIndex, old[left] == new[right] {
            left = old.index(after: left)
            right = new.index(after: right)
        }
        return LiveTextEdit(removed: String(old[left...]), insert: String(new[right...]))
    }

    /// Dictation never submits: line breaks would press Return in terminals and chat boxes.
    static func sanitize(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }
}

@MainActor
final class LiveTyper {
    enum Outcome: Equatable { case applied, targetChanged, failed }

    private let target: TextInsertion.Target
    private let insertion: TextInsertion
    private(set) var typed = ""
    private(set) var stopped = false

    init(target: TextInsertion.Target, insertion: TextInsertion) {
        self.target = target
        self.insertion = insertion
    }

    func sync(_ recognized: String) -> Outcome {
        guard !stopped else { return .targetChanged }
        let text = LiveTextEdit.sanitize(recognized)
        let edit = LiveTextEdit.between(typed, text)
        guard !edit.isEmpty else { return .applied }
        guard let current = insertion.currentTarget(), current.pid == target.pid,
              CFEqual(current.element, target.element) else {
            stopped = true
            return .targetChanged
        }
        let applied = supportsAccessibilityEditing(current.element)
            ? replaceWithAccessibility(current.element, edit)
            : typeWithKeyboard(edit, pid: current.pid)
        guard applied else {
            stopped = true
            return .failed
        }
        typed = text
        return .applied
    }

    private func supportsAccessibilityEditing(_ element: AXUIElement) -> Bool {
        var textSettable: DarwinBoolean = false, rangeSettable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &textSettable) == .success
            && textSettable.boolValue
            && AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &rangeSettable) == .success
            && rangeSettable.boolValue
    }

    private func replaceWithAccessibility(_ element: AXUIElement, _ edit: LiveTextEdit) -> Bool {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return false }
        var caret = CFRange()
        let removedLength = edit.removed.utf16.count
        // A user selection or a caret moved before our text means we no longer own the tail.
        guard AXValueGetValue(unsafeDowncast(rangeValue, to: AXValue.self), .cfRange, &caret),
              caret.length == 0, caret.location >= removedLength else { return false }
        var replace = CFRange(location: caret.location - removedLength, length: removedLength)
        if removedLength > 0 {
            guard text(of: element, in: replace) == edit.removed else { return false }
        }
        guard let replaceValue = AXValueCreate(.cfRange, &replace),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, replaceValue) == .success,
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, edit.insert as CFString) == .success
        else { return false }
        return true
    }

    private func text(of element: AXUIElement, in range: CFRange) -> String? {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         value, &result) == .success else { return nil }
        return result as? String
    }

    private func typeWithKeyboard(_ edit: LiveTextEdit, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        // Events go to the target process only, so a focus change can never redirect them.
        for _ in 0..<edit.removed.count {
            guard post(source, key: 51, text: nil, pid: pid) else { return false }
        }
        var chunk = ""
        for character in edit.insert {
            if chunk.utf16.count + character.utf16.count > 16 {
                guard post(source, key: 0, text: chunk, pid: pid) else { return false }
                chunk = ""
            }
            chunk.append(character)
        }
        return chunk.isEmpty || post(source, key: 0, text: chunk, pid: pid)
    }

    private func post(_ source: CGEventSource, key: CGKeyCode, text: String?, pid: pid_t) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = []
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.postToPid(pid)
        }
        return true
    }
}
