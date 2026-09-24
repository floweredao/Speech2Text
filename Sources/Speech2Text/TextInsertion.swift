import AppKit
import ApplicationServices

struct InsertionPolicy {
    static func allows(text: String, trusted: Bool, sameTarget: Bool, editable: Bool) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && trusted && sameTarget && editable
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
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        return Target(pid: app.processIdentifier, element: element)
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

    func copy(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    func insert(_ text: String, expected: Target?) -> String {
        guard isTrusted else { return "접근성 권한이 필요해요. 복사해서 직접 붙여넣을 수 있어요." }
        guard let current = currentTarget() else { return "입력 칸을 선택한 다음 붙여넣기를 눌러 주세요." }
        let same = expected.map { $0.pid == current.pid && CFEqual($0.element, current.element) } ?? true
        guard InsertionPolicy.allows(text: text, trusted: isTrusted, sameTarget: same, editable: isEditable(current)) else {
            return "입력 위치가 바뀌었거나 입력할 수 없어요. 텍스트는 여기에 보관했어요."
        }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(current.element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue,
           AXUIElementSetAttributeValue(current.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            return "선택한 입력 칸에 입력했어요."
        }
        // Paste as one literal payload; never synthesize Return (notably in terminals).
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false),
              copy(text) else { return "붙여넣기를 보내지 못했어요. 복사 버튼을 사용해 주세요." }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return "붙여넣기를 요청했어요. 입력되지 않았다면 칸을 선택하고 다시 눌러 주세요."
    }
}
