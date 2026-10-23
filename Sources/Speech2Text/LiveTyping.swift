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

    /// What to type into a field picked up again after live typing stopped: only text recognized after `base`.
    static func continuation(of text: String, after base: String) -> String {
        guard text.count > base.count else { return "" }
        var rest = text.dropFirst(base.count)
        // A word cut in half belongs to the speech heard while stopped; start at the next whole word.
        if let before = text.dropLast(rest.count).last, !before.isWhitespace, rest.first?.isWhitespace == false {
            rest = rest.drop { !$0.isWhitespace }
        }
        return String(rest.drop { $0.isWhitespace })
    }
}

@MainActor
final class LiveTyper {
    enum Outcome: Equatable {
        case applied, targetChanged, failed, userEdited

        /// The user moved on (another field, app, click or key); later speech may go to the field they settle in.
        var resumesInNextField: Bool { self == .targetChanged || self == .userEdited }
    }
    enum Mode { case accessibility, keyboard }
    private enum Step { case applied, unsafe(String), unsupported(String) }

    /// Accessibility edits start at an empty caret. A selection where dictation starts is replaced the way typing
    /// replaces it, so key events take over (Chromium address bars select their URL on focus).
    nonisolated static func startMode(selectionLength: Int) -> Mode {
        selectionLength == 0 ? .accessibility : .keyboard
    }

    private static let log = Logger(subsystem: "local.speech2text.app", category: "live-typing")
    private let target: TextInsertion.Target
    private let insertion: TextInsertion
    private var mode: Mode?
    // UTF-16 offset where our text begins; edits are computed from it, not from a caret that may lag.
    private var anchor: Int?
    private(set) var typed = ""
    private(set) var stopped = false
    private var userEdited = false
    /// System uptime of the user's first key or click after this field was picked (an `NSEvent.timestamp`).
    private(set) var userActedAt: TimeInterval?
    private let isShortcut: (KeyChord) -> Bool
    private var inputMonitor: Any?

    /// Tags our own key events so the input guard can tell them from the user's.
    nonisolated static let eventMarker: Int64 = 0x5332_5420

    init(target: TextInsertion.Target, insertion: TextInsertion, isShortcut: @escaping (KeyChord) -> Bool = { _ in false }) {
        self.target = target
        self.insertion = insertion
        self.isShortcut = isShortcut
        installInputGuard()
    }

    isolated deinit { removeInputGuard() }

    /// Any key or click the user makes after the field was picked ends typing into it, even before our first
    /// letter: an Enter pressed because nothing showed up yet must not be followed by text heard before it.
    /// Keyboard-mode fields (terminals) also report no usable caret. Our own events and our shortcuts don't count.
    nonisolated static func isUserEdit(type: NSEvent.EventType, sourceUserData: Int64, isShortcut: Bool) -> Bool {
        guard sourceUserData != eventMarker, !isShortcut else { return false }
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown: return true
        default: return false
        }
    }

    private func installInputGuard() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] event in MainActor.assumeIsolated { self?.observe(event) }
        }
    }

    private func removeInputGuard() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    private func observe(_ event: NSEvent) {
        let shortcut = event.type == .keyDown
            && isShortcut(KeyChord(keyCode: event.keyCode, modifiers: KeyModifiers(rawFlags: event.modifierFlags.rawValue)))
        let marker = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
        guard Self.isUserEdit(type: event.type, sourceUserData: marker, isShortcut: shortcut) else { return }
        Self.log.notice("stopped: user input (\(self.typed.isEmpty ? "nothing typed yet" : "after typing", privacy: .public))")
        userActedAt = event.timestamp
        stopped = true
        userEdited = true
        removeInputGuard()
    }

    func sync(_ recognized: String) -> Outcome {
        guard !stopped else { return userEdited ? .userEdited : .targetChanged }
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

    /// Only for the spoken Enter command, after the final text is in place and only into the same field.
    func pressReturn() -> Bool {
        guard !stopped, let current = insertion.currentTarget(), current.pid == target.pid,
              CFEqual(current.element, target.element),
              let source = CGEventSource(stateID: .privateState) else { return false }
        return post(source, key: 36, text: "\r", pid: current.pid)
    }

    private func supportsAccessibilityEditing(_ element: AXUIElement) -> Bool {
        // Chromium advertises these setters and returns success without changing the editor.
        // Native key events also deliver the input events that web editors require.
        var textSettable: DarwinBoolean = false, rangeSettable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &textSettable) == .success
            && InsertionPolicy.allowsAccessibilityWrite(inWebContent: insertion.isWebContent(element),
                                                       textSettable: textSettable.boolValue)
            && AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &rangeSettable) == .success
            && rangeSettable.boolValue
    }

    private func replaceWithAccessibility(_ element: AXUIElement, _ edit: LiveTextEdit) -> Step {
        if anchor == nil {
            guard let caret = selectedRange(element) else { return .unsupported("read caret") }
            guard Self.startMode(selectionLength: caret.length) == .accessibility else {
                return .unsupported("selection at start")
            }
            anchor = caret.location
        }
        guard let anchor else { return .unsupported("no anchor") }
        let removedLength = edit.removed.utf16.count
        let start = anchor + typed.utf16.count - removedLength
        var replace = CFRange(location: start, length: removedLength)
        // All of our text must still sit at the anchor before any edit, appends included; an unreadable range
        // is trusted like keystrokes.
        if !typed.isEmpty, let present = text(of: element, in: CFRange(location: anchor, length: typed.utf16.count)),
           present != typed {
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

    struct Keystroke: Equatable, Sendable {
        let key: CGKeyCode
        let text: String
    }

    /// Backspaces carry the backspace character: without it, web fields with the Korean input method active
    /// dropped or misplaced them, which mangled the start of the text when recognition revised it.
    nonisolated static func keystrokes(for edit: LiveTextEdit) -> [Keystroke] {
        var strokes = Array(repeating: Keystroke(key: 51, text: "\u{8}"), count: edit.removed.count)
        var chunk = ""
        for character in edit.insert {
            if chunk.utf16.count + character.utf16.count > 16 {
                strokes.append(Keystroke(key: 0, text: chunk))
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { strokes.append(Keystroke(key: 0, text: chunk)) }
        return strokes
    }

    private func typeWithKeyboard(_ edit: LiveTextEdit, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        // Events go to the target process only, so a focus change can never redirect them.
        return Self.keystrokes(for: edit).allSatisfy { post(source, key: $0.key, text: $0.text, pid: pid) }
    }

    private func post(_ source: CGEventSource, key: CGKeyCode, text: String, pid: pid_t) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            let units = Array(text.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.postToPid(pid)
        }
        return true
    }
}
