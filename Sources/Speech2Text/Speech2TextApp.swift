import AppKit
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
    private let shortcuts = GlobalShortcutMonitor()
    private var toggleItem: NSMenuItem?
    private var pasteItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.settingsAction = { [weak self] in self?.showSettings() }
        let overlay = NotchOverlayController(model: model)
        self.overlay = overlay
        overlay.start()
        overlay.present()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.image
        let menu = NSMenu()
        toggleItem = menu.addItem(withTitle: "", action: #selector(toggle), keyEquivalent: "")
        pasteItem = menu.addItem(withTitle: "", action: #selector(paste), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "받아쓰기 표시"), action: #selector(showOverlay), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "설정…"), action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: String(localized: "Speech2Text 종료"), action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        item.menu = menu
        statusItem = item
        model.shortcutsChanged = { [weak self] in self?.applyShortcuts() }
        applyShortcuts()
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
    private func applyShortcuts() {
        toggleItem?.title = menuTitle(String(localized: "받아쓰기 시작 / 마무리"), .toggleDictation)
        pasteItem?.title = menuTitle(String(localized: "마지막 받아쓰기 붙여넣기"), .pasteTranscript)
        guard model.capturingShortcut == nil else {
            shortcuts.stop()
            return
        }
        let refused = shortcuts.start(model.shortcuts) { [weak self] action in
            switch action {
            case .toggleDictation: self?.toggle()
            case .pasteTranscript: self?.paste()
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
        shortcuts.stop()
    }
}
