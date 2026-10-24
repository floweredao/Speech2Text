import AppKit
import DictationSpeech
import SwiftUI

@main
struct Speech2TextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let model = AppModel()
    private var overlay: NotchOverlayController?
    private var settings: NSWindow?
    private var statusItem: NSStatusItem?
    private let shortcuts = GlobalShortcutMonitor()
    private var updater: AppUpdater?
    private var toggleItem: NSMenuItem?
    private var pasteItem: NSMenuItem?
    private var cancelItem: NSMenuItem?
    private var copyItem: NSMenuItem?
    private var wakeCheck: WakeWordListener?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let launchArguments = ProcessInfo.processInfo.arguments
        if let index = launchArguments.firstIndex(of: "--wake-file"), launchArguments.indices.contains(index + 1) {
            checkWakePhrase(in: URL(fileURLWithPath: launchArguments[index + 1]), arguments: launchArguments)
            return
        }
        let updater = AppUpdater()
        self.updater = updater
        model.settingsAction = { [weak self] in self?.presentSettings() }
        let overlay = NotchOverlayController(model: model)
        self.overlay = overlay
        overlay.start()
        overlay.present()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image
        let menu = NSMenu()
        toggleItem = menu.addItem(withTitle: "", action: #selector(toggle), keyEquivalent: "")
        // Cancel and copy are here too so the overlay, which never takes keyboard focus, is not the only way.
        cancelItem = menu.addItem(withTitle: "", action: #selector(cancelDictation), keyEquivalent: "")
        copyItem = menu.addItem(withTitle: String(localized: "마지막 받아쓰기 복사"), action: #selector(copyTranscript), keyEquivalent: "")
        pasteItem = menu.addItem(withTitle: "", action: #selector(paste), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "받아쓰기 표시"), action: #selector(showOverlay), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "설정…"), action: #selector(showSettings), keyEquivalent: ",")
        if updater.isAvailable {
            menu.addItem(withTitle: String(localized: "업데이트 확인…"), action: #selector(checkForUpdates), keyEquivalent: "")
        }
        menu.addItem(withTitle: String(localized: "Speech2Text 종료"), action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        item.menu = menu
        statusItem = item
        DictationIntentRoute.register { [weak self] request in
            self?.model.handle(request)
            self?.overlay?.present()
        }
        model.onWake = { [weak self] in
            self?.model.handle(.start)
            self?.overlay?.present()
        }
        model.shortcutsChanged = { [weak self] in self?.applyShortcuts() }
        applyShortcuts()
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--audio-file"), arguments.indices.contains(index + 1) {
            model.autoInsert = !arguments.contains("--no-auto-insert")
            model.printsTurnsAndQuits = arguments.contains("--print-turns")
            let url = URL(fileURLWithPath: arguments[index + 1])
            Task {
                await model.speech.loadKey()
                model.transcribeFile(url)
            }
        } else {
            model.loadKey()
            model.beginWakeListening()
            showSettings()
        }
    }
    /// Diagnostic: runs the bundled wake-phrase model over an audio file, with no window, microphone or network.
    /// Prints `WAKE <n>` per detection and `WAKE_TOTAL <n>` at the end, then quits.
    private func checkWakePhrase(in file: URL, arguments: [String]) {
        let phrase = arguments.firstIndex(of: "--wake-phrase").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? model.wakePhrase
        let sensitivity = arguments.firstIndex(of: "--wake-sensitivity")
            .flatMap { arguments.indices.contains($0 + 1) ? WakeSensitivity(rawValue: arguments[$0 + 1]) : nil }
            ?? model.wakeSensitivity
        guard let modelURL = Bundle.main.url(forResource: "WakeWord", withExtension: nil),
              let listener = try? WakeWordListener(model: modelURL, audioFile: file),
              let pieces = listener.tokenizer.pieces(for: phrase) else {
            print("WAKE_UNAVAILABLE")
            exit(2)
        }
        var heard = 0
        listener.onWake = {
            heard += 1
            print("WAKE \(heard)")
        }
        listener.onFailure = { _ in
            print("WAKE_TOTAL \(heard)")
            fflush(stdout)
            NSApp.terminate(nil)
        }
        wakeCheck = listener
        listener.start(pieces: pieces, sensitivity: sensitivity, deviceUID: nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    private func applyShortcuts() {
        toggleItem?.title = menuTitle(String(localized: "받아쓰기 시작 / 마무리"), .toggleDictation)
        pasteItem?.title = menuTitle(String(localized: "마지막 받아쓰기 붙여넣기"), .pasteTranscript)
        cancelItem?.title = menuTitle(String(localized: "받아쓰기 취소"), .cancelDictation)
        guard model.capturingShortcut == nil else {
            shortcuts.stop()
            return
        }
        let refused = shortcuts.start(model.shortcuts) { [weak self] action in
            switch action {
            case .toggleDictation: self?.toggle()
            case .pasteTranscript: self?.paste()
            case .cancelDictation: self?.cancelDictation()
            }
        }
        model.shortcutProblem = refused.isEmpty ? ""
            : String(localized: "\(refused.map { "'\($0.title)'" }.joined(separator: ", ")) 단축키를 등록하지 못했어요. 다른 앱이 쓰고 있을 수 있어요. 다른 키를 골라 주세요.")
    }
    private func menuTitle(_ title: String, _ action: ShortcutAction) -> String {
        model.shortcuts[action].map { "\(title)  \($0.label)" } ?? title
    }
    @objc private func toggle() { model.toggleRecording(); overlay?.present() }
    @objc private func paste() { model.pasteTranscript(); overlay?.present() }
    @objc private func cancelDictation() { model.cancel(); overlay?.present() }
    @objc private func copyTranscript() { model.copyTranscript(); overlay?.present() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(cancelDictation): model.isBusy
        // Same rule as the overlay: unconfirmed text heard before a cancel is never offered for copy.
        case #selector(copyTranscript): DictationDisplayState(model: model).offersTranscriptActions
        default: true
        }
    }
    @objc private func showOverlay() { model.showOverlay(); overlay?.present() }
    @objc private func showSettings() { model.openSettings() }
    @objc private func checkForUpdates() { updater?.checkForUpdates() }
    private func presentSettings() {
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Speech2Text"
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.minSize = NSSize(width: 440, height: 420)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settings = window
        }
        model.accessibilityGranted = AXIsProcessTrusted()
        NSApp.activate()
        settings?.makeKeyAndOrderFront(nil)
        // macOS can refuse the activation (launched from Finder or a script); then no key or activation notice
        // arrives, and Settings must not keep the overlay hidden. A granted activation hides it again.
        model.appActivationChanged(isActive: NSApp.isActive, settingsIsKey: true)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        model.appActivationChanged(isActive: true, settingsIsKey: settings?.isKeyWindow == true)
    }
    func applicationDidResignActive(_ notification: Notification) {
        model.appActivationChanged(isActive: false, settingsIsKey: settings?.isKeyWindow == true)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        model.appActivationChanged(isActive: NSApp.isActive, settingsIsKey: true)
    }
    func windowDidResignKey(_ notification: Notification) {
        model.settingsFocused = false
    }
    func windowWillClose(_ notification: Notification) {
        model.settingsFocused = false
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        model.cancel()
        overlay?.stop()
        shortcuts.stop()
    }
}
