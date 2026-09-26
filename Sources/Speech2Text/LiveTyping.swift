import AppKit
import ApplicationServices
import os

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
    private enum Mode { case accessibility, keyboard }
    private enum Step { case applied, unsafe(String), unsupported(String) }

    private static let log = Logger(subsystem: "local.speech2text.app", category: "live-typing")
    private let target: TextInsertion.Target
    private let insertion: TextInsertion
    private var mode: Mode?
    // UTF-16 offset where our text begins; edits are computed from it, not from a caret that may lag.
    private var anchor: Int?
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
            Self.log.notice("stopped: focus changed")
            stopped = true
            return .targetChanged
        }
        if mode == nil { mode = supportsAccessibilityEditing(current.element) ? .accessibility : .keyboard }
        if mode == .accessibility {
            switch replaceWithAccessibility(current.element, edit) {
            case .applied:
                typed = text
                return .applied
            case .unsafe(let stage):
                Self.log.error("stopped: \(stage, privacy: .public)")
                stopped = true
                return .failed
            case .unsupported(let stage):
                Self.log.error("accessibility write failed: \(stage, privacy: .public)")
                guard typed.isEmpty else {
                    stopped = true
                    return .failed
                }
                mode = .keyboard
            }
        }
        guard typeWithKeyboard(edit, pid: current.pid) else {
            Self.log.error("stopped: key event creation failed")
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

    private func replaceWithAccessibility(_ element: AXUIElement, _ edit: LiveTextEdit) -> Step {
        if anchor == nil {
            guard let caret = selectedRange(element) else { return .unsupported("read caret") }
            guard caret.length == 0 else { return .unsafe("user selection at start") }
            anchor = caret.location
        }
        guard let anchor else { return .unsupported("no anchor") }
        let removedLength = edit.removed.utf16.count
        let start = anchor + typed.utf16.count - removedLength
        var replace = CFRange(location: start, length: removedLength)
        // Our own text must still be there before we overwrite it; an unreadable range is trusted like keystrokes.
        if removedLength > 0, let present = text(of: element, in: replace), present != edit.removed {
            return .unsafe("dictated text was edited")
        }
        guard let replaceValue = AXValueCreate(.cfRange, &replace),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, replaceValue) == .success
        else { return .unsupported("set range") }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, edit.insert as CFString) == .success
        else { return .unsupported("set text") }
        var caret = CFRange(location: start + edit.insert.utf16.count, length: 0)
        if let caretValue = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caretValue)
        }
        return .applied
    }

    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) ? range : nil
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
