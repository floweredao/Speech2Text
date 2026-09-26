import Carbon.HIToolbox
import Foundation

enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case toggleDictation, pasteTranscript

    var title: String {
        switch self {
        case .toggleDictation: String(localized: "받아쓰기 시작 / 마무리")
        case .pasteTranscript: String(localized: "마지막 결과 붙여넣기")
        }
    }
}

enum ModifierKey: String, CaseIterable, Codable, Sendable {
    case leftControl, rightControl, leftOption, rightOption, leftShift, rightShift, leftCommand, rightCommand, function

    /// Modifier keys held according to `NSEvent.modifierFlags.rawValue`, including the device-dependent side bits.
    static func held(inRawFlags raw: UInt) -> Set<ModifierKey> {
        let sides: [(ModifierKey, UInt)] = [
            (.leftControl, 0x1), (.leftShift, 0x2), (.rightShift, 0x4), (.leftCommand, 0x8),
            (.rightCommand, 0x10), (.leftOption, 0x20), (.rightOption, 0x40), (.rightControl, 0x2000),
        ]
        var held = Set(sides.filter { raw & $0.1 != 0 }.map(\.0))
        // Some keyboards and remappers omit the side bits: count the generic flag as the left key.
        for group in ModifierGroup.allCases where raw & group.genericFlag != 0 {
            if let right = group.right, !held.contains(right), !held.contains(group.left) { held.insert(group.left) }
            if group.right == nil { held.insert(group.left) }
        }
        return held
    }
}

enum ModifierGroup: CaseIterable {
    case control, option, shift, command, function

    var left: ModifierKey {
        switch self {
        case .control: .leftControl
        case .option: .leftOption
        case .shift: .leftShift
        case .command: .leftCommand
        case .function: .function
        }
    }

    var right: ModifierKey? {
        switch self {
        case .control: .rightControl
        case .option: .rightOption
        case .shift: .rightShift
        case .command: .rightCommand
        case .function: nil
        }
    }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        case .function: "fn"
        }
    }

    var spokenName: String {
        switch self {
        case .control: "Control"
        case .option: "Option"
        case .shift: "Shift"
        case .command: "Command"
        case .function: "fn"
        }
    }

    var genericFlag: UInt {
        switch self {
        case .control: 1 << 18
        case .option: 1 << 19
        case .shift: 1 << 17
        case .command: 1 << 20
        case .function: 1 << 23
        }
    }
}

struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8
    static let control = KeyModifiers(rawValue: 1 << 0)
    static let option = KeyModifiers(rawValue: 1 << 1)
    static let shift = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)

    private static let ordered: [(KeyModifiers, ModifierGroup, Int)] = [
        (.control, .control, controlKey), (.option, .option, optionKey),
        (.shift, .shift, shiftKey), (.command, .command, cmdKey),
    ]

    init(rawValue: UInt8) { self.rawValue = rawValue }

    init(rawFlags: UInt) {
        self = Self(Self.ordered.filter { rawFlags & $0.1.genericFlag != 0 }.map(\.0))
    }

    var symbols: String { Self.ordered.filter { contains($0.0) }.map(\.1.symbol).joined() }
    var spokenNames: [String] { Self.ordered.filter { contains($0.0) }.map(\.1.spokenName) }
    var carbonFlags: UInt32 { UInt32(Self.ordered.filter { contains($0.0) }.reduce(0) { $0 | $1.2 }) }
}

struct KeyChord: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: KeyModifiers

    /// A chord must not swallow ordinary typing: it needs ⌃, ⌥ or ⌘, unless it is a function key.
    var isAllowed: Bool { KeyNames.isFunctionKey(keyCode) || !modifiers.subtracting(.shift).isEmpty }
    var label: String { modifiers.symbols + KeyNames.name(keyCode) }
    var spokenLabel: String { (modifiers.spokenNames + [KeyNames.name(keyCode)]).joined(separator: " ") }
}

enum ShortcutTrigger: Codable, Hashable, Sendable {
    /// A key with modifiers, delivered by a system hot key. Works without extra permission.
    case key(KeyChord)
    /// Only modifier keys pressed and released together, such as both Shift keys or the right ⌘.
    case modifiers(Set<ModifierKey>)

    var label: String {
        switch self {
        case .key(let chord): chord.label
        case .modifiers(let keys): Self.describe(keys, name: \.symbol)
        }
    }

    var spokenLabel: String {
        switch self {
        case .key(let chord): chord.spokenLabel
        case .modifiers(let keys): Self.describe(keys, name: \.spokenName)
        }
    }

    private static func describe(_ keys: Set<ModifierKey>, name: KeyPath<ModifierGroup, String>) -> String {
        ModifierGroup.allCases.compactMap { group -> String? in
            let left = keys.contains(group.left)
            let right = group.right.map(keys.contains) ?? false
            let name = group[keyPath: name]
            switch (left, right) {
            case (true, true): return String(localized: "양쪽 \(name)")
            case (true, false): return group.right == nil ? name : String(localized: "왼쪽 \(name)")
            case (false, true): return String(localized: "오른쪽 \(name)")
            case (false, false): return nil
            }
        }.joined(separator: " + ")
    }
}

struct Shortcut: Codable, Hashable, Sendable {
    static let maxTaps = 3
    var trigger: ShortcutTrigger
    var taps: Int

    var label: String { trigger.label + Self.tapSuffix(taps) }
    var spokenLabel: String { trigger.spokenLabel + Self.tapSuffix(taps) }

    private static func tapSuffix(_ taps: Int) -> String {
        switch taps {
        case 2: String(localized: " 두 번")
        case 3: String(localized: " 세 번")
        default: ""
        }
    }
}

struct ShortcutSettings: Codable, Equatable, Sendable {
    var toggleDictation: Shortcut?
    var pasteTranscript: Shortcut?

    static let standard = ShortcutSettings(
        toggleDictation: Shortcut(trigger: .key(KeyChord(keyCode: UInt16(kVK_ANSI_D), modifiers: [.control, .option])), taps: 1),
        pasteTranscript: Shortcut(trigger: .key(KeyChord(keyCode: UInt16(kVK_ANSI_V), modifiers: [.control, .option])), taps: 1))
    static let defaultsKey = "shortcuts"

    subscript(action: ShortcutAction) -> Shortcut? {
        get {
            switch action {
            case .toggleDictation: toggleDictation
            case .pasteTranscript: pasteTranscript
            }
        }
        set {
            switch action {
            case .toggleDictation: toggleDictation = newValue
            case .pasteTranscript: pasteTranscript = newValue
            }
        }
    }

    var bindings: [Shortcut: ShortcutAction] {
        Dictionary(ShortcutAction.allCases.compactMap { action in self[action].map { ($0, action) } },
                   uniquingKeysWith: { first, _ in first })
    }

    var usesModifierOnlyTrigger: Bool {
        bindings.keys.contains { if case .modifiers = $0.trigger { true } else { false } }
    }

    func action(using shortcut: Shortcut, except action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self[$0] == shortcut }
    }

    static func load(from defaults: UserDefaults = .standard) -> ShortcutSettings {
        guard let data = defaults.data(forKey: defaultsKey) else { return .standard }
        // Unreadable stored settings fall back to the defaults instead of leaving no shortcut.
        return (try? JSONDecoder().decode(ShortcutSettings.self, from: data)) ?? .standard
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Turns modifier key state changes into "tapped" chords: modifiers pressed and all released
/// quickly with no other key or click in between. Returns every modifier that was down.
struct ModifierTapDetector {
    static let maxHold: TimeInterval = 0.6
    private var held: Set<ModifierKey> = []
    private var pressed: Set<ModifierKey> = []
    private var began: TimeInterval = 0
    private var spoiled = false

    mutating func update(held now: Set<ModifierKey>, at time: TimeInterval) -> Set<ModifierKey>? {
        if held.isEmpty, !now.isEmpty {
            pressed = []
            spoiled = false
            began = time
        }
        pressed.formUnion(now)
        held = now
        guard now.isEmpty, !pressed.isEmpty else { return nil }
        defer { pressed = [] }
        return spoiled || time - began > Self.maxHold ? nil : pressed
    }

    /// A key press or click while modifiers are down means they were used as ordinary modifiers.
    mutating func otherInput() {
        if !held.isEmpty { spoiled = true }
    }
}

/// Counts repeated presses of one trigger and decides which action runs. A shorter sequence waits
/// `interval` only when a longer sequence of the same trigger is also bound.
struct TapSequenceRecognizer {
    static let interval: TimeInterval = 0.5
    var bindings: [Shortcut: ShortcutAction]
    private var trigger: ShortcutTrigger?
    private var taps = 0
    private var lastTap: TimeInterval = 0
    /// When the waiting shorter sequence should run if no further press arrives.
    private(set) var deadline: TimeInterval?

    init(bindings: [Shortcut: ShortcutAction] = [:]) { self.bindings = bindings }

    mutating func press(_ pressed: ShortcutTrigger, at time: TimeInterval) -> [ShortcutAction] {
        var fired: [ShortcutAction] = []
        if pressed == trigger, time - lastTap <= Self.interval {
            taps += 1
        } else {
            fired = flush()
            trigger = pressed
            taps = 1
        }
        lastTap = time
        deadline = nil
        let longest = bindings.keys.filter { $0.trigger == pressed }.map(\.taps).max() ?? 0
        let bound = bindings[Shortcut(trigger: pressed, taps: taps)]
        if taps >= longest {
            if let bound { fired.append(bound) }
            reset()
        } else if bound != nil {
            deadline = time + Self.interval
        }
        return fired
    }

    /// No further press arrived in time: run the shorter sequence that was waiting.
    mutating func expire(at time: TimeInterval) -> [ShortcutAction] {
        guard let deadline, time >= deadline else { return [] }
        return flush()
    }

    /// Typing or clicking ends a modifier-only sequence; a waiting shorter one runs now.
    mutating func interrupt() -> [ShortcutAction] {
        guard case .modifiers = trigger else { return [] }
        return flush()
    }

    private mutating func flush() -> [ShortcutAction] {
        defer { reset() }
        guard deadline != nil, let trigger, let action = bindings[Shortcut(trigger: trigger, taps: taps)] else { return [] }
        return [action]
    }

    private mutating func reset() {
        trigger = nil
        taps = 0
        deadline = nil
    }
}

enum KeyNames {
    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥",
        49: "Space", 50: "`", 51: "⌫", 53: "⎋", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func isFunctionKey(_ code: UInt16) -> Bool { functionKeys[code] != nil }
    static func name(_ code: UInt16) -> String { functionKeys[code] ?? names[code] ?? String(localized: "키 \(Int(code))") }
}
