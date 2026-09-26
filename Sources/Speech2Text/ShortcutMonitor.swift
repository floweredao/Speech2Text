import AppKit
import Carbon

/// Delivers the user's shortcuts system-wide. Key chords use Carbon hot keys, which need no
/// permission and keep the key from reaching the focused app. Modifier-only triggers watch
/// modifier changes through NSEvent monitors, which macOS allows only with the control permission.
@MainActor
final class GlobalShortcutMonitor {
    nonisolated private static let signature: OSType = 0x53325458
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var chords: [UInt32: KeyChord] = [:]
    private var monitors: [Any] = []
    private var recognizer = TapSequenceRecognizer()
    private var detector = ModifierTapDetector()
    private var expiry: Task<Void, Never>?
    private var perform: (@MainActor (ShortcutAction) -> Void)?

    /// Returns the actions whose key chord macOS refused, for example because another app owns it.
    func start(_ settings: ShortcutSettings, perform: @escaping @MainActor (ShortcutAction) -> Void) -> [ShortcutAction] {
        stop()
        self.perform = perform
        let bindings = settings.bindings
        recognizer = TapSequenceRecognizer(bindings: bindings)
        var refused: [KeyChord] = []
        let keyChords = Set(bindings.keys.compactMap { if case .key(let chord) = $0.trigger { chord } else { nil } })
        if !keyChords.isEmpty {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            if InstallEventHandler(GetApplicationEventTarget(), Self.receive, 1, &spec,
                                   Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr {
                for (index, chord) in keyChords.enumerated() {
                    let id = UInt32(index + 1)
                    var reference: EventHotKeyRef?
                    let status = RegisterEventHotKey(UInt32(chord.keyCode), chord.modifiers.carbonFlags,
                                                     EventHotKeyID(signature: Self.signature, id: id),
                                                     GetApplicationEventTarget(), 0, &reference)
                    if status == noErr, let reference {
                        hotKeys.append(reference)
                        chords[id] = chord
                    } else {
                        refused.append(chord)
                    }
                }
            } else {
                refused = Array(keyChords)
            }
        }
        if settings.usesModifierOnlyTrigger {
            let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }) { monitors.append(local) }
        }
        return bindings.compactMap { shortcut, action in
            if case .key(let chord) = shortcut.trigger, refused.contains(chord) { action } else { nil }
        }
    }

    func stop() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        chords.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        expiry?.cancel()
        expiry = nil
        recognizer = TapSequenceRecognizer()
        detector = ModifierTapDetector()
        perform = nil
    }

    nonisolated private static let receive: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
              id.signature == signature else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<GlobalShortcutMonitor>.fromOpaque(context).takeUnretainedValue()
        let hotKey = id.id
        MainActor.assumeIsolated { owner.hotKeyPressed(hotKey) }
        return noErr
    }

    private func hotKeyPressed(_ id: UInt32) {
        guard let chord = chords[id] else { return }
        // The hot key consumes the key press, so the modifier monitor never sees it.
        detector.otherInput()
        deliver(recognizer.press(.key(chord), at: ProcessInfo.processInfo.systemUptime))
    }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged {
            let held = ModifierKey.held(inRawFlags: event.modifierFlags.rawValue)
            if let tapped = detector.update(held: held, at: event.timestamp) {
                deliver(recognizer.press(.modifiers(tapped), at: event.timestamp))
            }
        } else {
            detector.otherInput()
            deliver(recognizer.interrupt())
        }
    }

    private func deliver(_ actions: [ShortcutAction]) {
        expiry?.cancel()
        expiry = nil
        if let deadline = recognizer.deadline {
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                guard !Task.isCancelled, let self else { return }
                self.deliver(self.recognizer.expire(at: ProcessInfo.processInfo.systemUptime))
            }
        }
        for action in actions { perform?(action) }
    }
}

/// Captures a new shortcut from the settings window. Pressing the same key or modifiers two or
/// three times in quick succession records a multi-tap shortcut; Escape alone cancels.
@MainActor
final class ShortcutRecorder {
    private var monitor: Any?
    private var detector = ModifierTapDetector()
    private var trigger: ShortcutTrigger?
    private var taps = 0
    private var lastTap: TimeInterval = 0
    private var commitTask: Task<Void, Never>?
    private weak var model: AppModel?

    var isRecording: Bool { monitor != nil }

    func begin(_ action: ShortcutAction, model: AppModel) {
        cancel()
        self.model = model
        model.shortcutNote = ""
        model.shortcutPreview = ""
        model.capturingShortcut = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    func cancel() {
        guard isRecording else { return }
        end()
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            let held = ModifierKey.held(inRawFlags: event.modifierFlags.rawValue)
            if let tapped = detector.update(held: held, at: event.timestamp) { tap(.modifiers(tapped), at: event.timestamp) }
            return false
        }
        detector.otherInput()
        guard !event.isARepeat else { return true }
        let chord = KeyChord(keyCode: event.keyCode, modifiers: KeyModifiers(rawFlags: event.modifierFlags.rawValue))
        if chord.keyCode == UInt16(kVK_Escape), chord.modifiers.isEmpty {
            end()
        } else if chord.isAllowed {
            tap(.key(chord), at: event.timestamp)
        } else {
            model?.shortcutNote = "\(chord.label)은 글자 입력을 막아서 쓸 수 없어요. ⌃·⌥·⌘와 함께 누르거나, 수정 키만 누르거나, F1–F20을 써 주세요."
        }
        return true
    }

    private func tap(_ pressed: ShortcutTrigger, at time: TimeInterval) {
        if pressed == trigger, time - lastTap <= TapSequenceRecognizer.interval {
            taps += 1
        } else {
            trigger = pressed
            taps = 1
        }
        lastTap = time
        model?.shortcutNote = ""
        model?.shortcutPreview = Shortcut(trigger: pressed, taps: taps).label
        commitTask?.cancel()
        if taps >= Shortcut.maxTaps {
            commit()
        } else {
            commitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(TapSequenceRecognizer.interval))
                guard !Task.isCancelled else { return }
                self?.commit()
            }
        }
    }

    private func commit() {
        guard let model, let action = model.capturingShortcut, let trigger else { return end() }
        let shortcut = Shortcut(trigger: trigger, taps: taps)
        end()
        if let owner = model.shortcuts.action(using: shortcut, except: action) {
            model.shortcutNote = "\(shortcut.label)은 이미 '\(owner.title)'에 쓰고 있어요."
        } else {
            model.shortcuts[action] = shortcut
        }
    }

    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        commitTask?.cancel()
        commitTask = nil
        trigger = nil
        taps = 0
        detector = ModifierTapDetector()
        model?.shortcutPreview = ""
        model?.capturingShortcut = nil
    }
}
