import AppKit
import ApplicationServices

struct InsertionPolicy {
    static func allowsAccessibilityWrite(inWebContent: Bool, textSettable: Bool) -> Bool {
        textSettable && !inWebContent
    }

    /// What a manual insertion sends: the same single-line payload live typing sends, because a line break
    /// presses Return in a terminal and sends the message in a chat box.
    static func payload(_ text: String) -> String { LiveTextEdit.sanitize(text) }

    static func allows(text: String, trusted: Bool, sameTarget: Bool, editable: Bool) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && trusted && sameTarget && editable
    }
}

/// What the pasteboard held before the automatic paste replaced it.
@MainActor
struct PasteboardRestore {
    let pasteboard: NSPasteboard
    let items: [[(NSPasteboard.PasteboardType, Data)]]
    /// The pasteboard's change count right after the paste wrote to it.
    let changeCount: Int

    static func contents(of pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    /// Gives back the earlier contents, or nothing when the clipboard was empty, unless something was copied after
    /// the paste: that copy is the user's newest and stays. The given-back items are marked transient, because
    /// clipboard managers already recorded them when they were first copied.
    @discardableResult
    func restore() -> Bool {
        guard pasteboard.changeCount == changeCount else { return false }
        pasteboard.clearContents()
        let restored = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            for type in TextInsertion.transientPasteTypes where !item.types.contains(type) { item.setString("", forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
        return true
    }
}

@MainActor
final class TextInsertion {
    struct Target {
        let pid: pid_t
        let element: AXUIElement
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        // This documented key avoids importing the SDK's mutable C global into Swift isolation.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func currentTarget() -> Target? {
        guard isTrusted,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let element = Self.focusedElement { () -> AXUIElement? in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        } wake: {
            _ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return element.map { Target(pid: app.processIdentifier, element: $0) }
    }

    /// Chromium and Electron apps (Discord, browsers) switch their accessibility tree off after a few idle minutes
    /// and then report no focused element; reading attributes does not switch it back on. A failed lookup asks the
    /// app to turn it on again (Electron's documented switch, ignored by other apps). The tree is back within about
    /// a second, so the next lookup, made on the next live transcript update, finds the field.
    static func focusedElement<Element>(lookup: () -> Element?, wake: () -> Void) -> Element? {
        if let element = lookup() { return element }
        wake()
        return nil
    }

    func isEditable(_ target: Target) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(target.element, kAXRoleAttribute as CFString, &role)
        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        guard let role = role as? String, textRoles.contains(role) else { return false }
        var enabled: CFTypeRef?
        if AXUIElementCopyAttributeValue(target.element, kAXEnabledAttribute as CFString, &enabled) == .success,
           let enabled = enabled as? Bool, !enabled { return false }
        // A selected-text setter is definitive. Other text controls accept native paste.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue { return true }
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(target.element, "AXEditable" as CFString, &editable) == .success,
           let editable = editable as? Bool { return editable }
        // Terminal renderers expose a text area without a writable AX value.
        return role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXComboBoxRole
    }

    func isWebContent(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        while let element = current {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXWebArea" { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
    }

    /// Types that tell clipboard managers and Universal Clipboard to skip a write (the nspasteboard.org convention).
    /// Only the automatic paste adds them: a Copy the user asked for belongs in their clipboard history.
    static let transientPasteTypes: [NSPasteboard.PasteboardType] =
        [.init("org.nspasteboard.TransientType"), .init("org.nspasteboard.AutoGeneratedType")]

    func copy(_ text: String, to pasteboard: NSPasteboard = .general, transient: Bool = false) -> Bool {
        guard !text.isEmpty else { return false }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        for type in transient ? Self.transientPasteTypes : [] {
            pasteboard.setString("", forType: type)
        }
        return true
    }

    /// How long the automatic paste keeps the dictation on the pasteboard before giving back what it held. The target
    /// app reads the pasteboard when it handles Cmd-V, which a busy app does late; a copy the user makes in the
    /// meantime is never overwritten, so a longer wait costs nothing.
    static let clipboardRestoreDelay: Duration = .milliseconds(1500)

    /// Puts the dictation on the pasteboard for an automatic paste and returns what puts the earlier contents back.
    func copyForPaste(_ text: String, to pasteboard: NSPasteboard = .general) -> PasteboardRestore? {
        let held = PasteboardRestore.contents(of: pasteboard)
        guard copy(text, to: pasteboard, transient: true) else { return nil }
        return PasteboardRestore(pasteboard: pasteboard, items: held, changeCount: pasteboard.changeCount)
    }

    func insert(_ text: String, expected: Target?) -> String {
        let payload = InsertionPolicy.payload(text)
        guard isTrusted else { return String(localized: "'\(ControlPermissionPane.current.title)' 권한이 필요해요. 복사해서 직접 붙여넣을 수 있어요.") }
        guard let current = currentTarget() else { return String(localized: "입력 칸을 선택한 다음 붙여넣기를 눌러 주세요.") }
        let same = expected.map { $0.pid == current.pid && CFEqual($0.element, current.element) } ?? true
        guard InsertionPolicy.allows(text: payload, trusted: isTrusted, sameTarget: same, editable: isEditable(current)) else {
            return String(localized: "입력 위치가 바뀌었거나 입력할 수 없어요. 텍스트는 여기에 보관했어요.")
        }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(current.element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           InsertionPolicy.allowsAccessibilityWrite(inWebContent: isWebContent(current.element),
                                                   textSettable: settable.boolValue),
           AXUIElementSetAttributeValue(current.element, kAXSelectedTextAttribute as CFString, payload as CFString) == .success {
            return String(localized: "선택한 입력 칸에 입력했어요.")
        }
        // Paste as one literal payload; never synthesize Return (notably in terminals).
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false),
              let restore = copyForPaste(payload) else { return String(localized: "붙여넣기를 보내지 못했어요. 복사 버튼을 사용해 주세요.") }
        // Sent to the field's own app, the way live typing sends its keys: a focus change between the check above and
        // delivery cannot paste into another app, and the marker tells the input guard these keys are the app's own.
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: LiveTyper.eventMarker)
            event.postToPid(current.pid)
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.clipboardRestoreDelay)
            restore.restore()
        }
        return String(localized: "붙여넣기를 요청했어요. 입력되지 않았다면 칸을 선택하고 다시 눌러 주세요.")
    }
}
