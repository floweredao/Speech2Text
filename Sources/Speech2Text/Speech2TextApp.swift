import AppKit
import Carbon
import SwiftUI

@main
struct Speech2TextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var overlay: NotchOverlayController?
    private var settings: NSWindow?
    private var statusItem: NSStatusItem?
    private let hotkeys = DictationHotkeys()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.settingsAction = { [weak self] in self?.showSettings() }
        let overlay = NotchOverlayController(model: model)
        self.overlay = overlay
        overlay.start()
        overlay.present()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Speech2Text")
        let menu = NSMenu()
        menu.addItem(withTitle: "받아쓰기 시작 / 마무리  ⌃⌥D", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(withTitle: "마지막 받아쓰기 붙여넣기  ⌃⌥V", action: #selector(paste), keyEquivalent: "")
        menu.addItem(withTitle: "받아쓰기 표시", action: #selector(showOverlay), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "설정…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Speech2Text 종료", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        item.menu = menu
        statusItem = item
        do {
            try hotkeys.register { [weak self] id in
                guard let self else { return }
                if id == 1 { self.toggle() } else { self.paste() }
            }
        } catch { model.feedback = error.localizedDescription }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--audio-file"), arguments.indices.contains(index + 1) {
            model.autoInsert = !arguments.contains("--no-auto-insert")
            let url = URL(fileURLWithPath: arguments[index + 1])
            Task {
                await model.speech.loadKey()
                model.transcribeFile(url)
            }
        } else {
            model.loadKey()
            showSettings()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    @objc private func toggle() { model.toggleRecording(); overlay?.present() }
    @objc private func paste() { model.pasteTranscript(); overlay?.present() }
    @objc private func showOverlay() { model.overlayVisible = true; overlay?.present() }
    @objc private func showSettings() {
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Speech2Text"
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.minSize = NSSize(width: 440, height: 420)
            window.isReleasedWhenClosed = false
            window.center()
            settings = window
        }
        model.accessibilityGranted = AXIsProcessTrusted()
        NSApp.activate()
        settings?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        model.cancel()
        overlay?.stop()
        hotkeys.unregister()
    }
}

@MainActor
final class DictationHotkeys {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var callback: (@MainActor (UInt32) -> Void)?

    func register(callback: @escaping @MainActor (UInt32) -> Void) throws {
        unregister()
        self.callback = callback
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(GetApplicationEventTarget(), Self.receive, 1, &spec,
                                  Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else {
            throw HotkeyError.conflict
        }
        for (id, key) in [(UInt32(1), kVK_ANSI_D), (UInt32(2), kVK_ANSI_V)] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey),
                                            EventHotKeyID(signature: 0x53325458, id: id),
                                            GetApplicationEventTarget(), 0, &reference)
            guard result == noErr, let reference else {
                unregister()
                throw HotkeyError.conflict
            }
            references.append(reference)
        }
    }
    nonisolated private static let receive: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
              id.signature == 0x53325458 else { return OSStatus(eventNotHandledErr) }
        let owner = Unmanaged<DictationHotkeys>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { owner.callback?(id.id) }
        return noErr
    }
    func unregister() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        callback = nil
    }
    enum HotkeyError: LocalizedError {
        case conflict
        var errorDescription: String? { "단축키를 등록하지 못했어요. 메뉴바에서 받아쓰기를 시작해 주세요." }
    }
}
