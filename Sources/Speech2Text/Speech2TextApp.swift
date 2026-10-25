import AppKit
import AVFoundation
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
    private var demoRecording: DemoRecording?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let launchArguments = ProcessInfo.processInfo.arguments
        if let dir = Self.value(after: "--demo-capture", in: launchArguments) {
            let locale = Self.value(after: "--demo", in: launchArguments).flatMap(AppModel.DemoLocale.init) ?? .en
            DemoCapturer.captureAll(to: URL(fileURLWithPath: dir), locale: locale, model: model)
            exit(0)
        }
        if let index = launchArguments.firstIndex(of: "--wake-file"), launchArguments.indices.contains(index + 1) {
            checkWakePhrase(in: URL(fileURLWithPath: launchArguments[index + 1]), arguments: launchArguments)
            return
        }
        // Setup: stores the Jev key read from a file in this app's Keychain without showing it, then quits.
        if let index = launchArguments.firstIndex(of: "--store-jev-key"), launchArguments.indices.contains(index + 1) {
            let key = try? String(contentsOfFile: launchArguments[index + 1], encoding: .utf8)
            print(key.map(JevKeychain.save) == true ? "JEV_KEY_STORED" : "JEV_KEY_NOT_STORED")
            exit(0)
        }
        if let file = Self.value(after: "--edit-corpus", in: launchArguments) {
            let key = Self.value(after: "--jev-key-file", in: launchArguments)
                .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? JevKeychain.load()
            Task {
                await EditCorpus.run(file: file, key: key)
                exit(0)
            }
            return
        }
        // A --print-turns file run is a diagnostic that quits when done: no overlay, menu bar item, shortcuts or
        // update check, so it never shows up next to the running app.
        if let index = launchArguments.firstIndex(of: "--audio-file"), launchArguments.indices.contains(index + 1),
           launchArguments.contains("--print-turns") {
            transcribeFile(launchArguments[index + 1], arguments: launchArguments)
            return
        }
        let demoLocale = Self.value(after: "--demo", in: launchArguments).flatMap(AppModel.DemoLocale.init)
        // A demo run never reaches the network, so it gets no update check.
        let updater = demoLocale == nil ? AppUpdater() : nil
        self.updater = updater
        model.settingsAction = { [weak self] in self?.presentSettings() }
        if demoLocale != nil {
            NotchOverlayController.demoScreenID = Self.value(after: "--demo-screen", in: launchArguments).flatMap(UInt32.init)
        }
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
        if updater?.isAvailable == true {
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
        let arguments = launchArguments
        if let demoLocale {
            runDemo(demoLocale, arguments: arguments)
        } else if let index = arguments.firstIndex(of: "--audio-file"), arguments.indices.contains(index + 1) {
            transcribeFile(arguments[index + 1], arguments: arguments)
        } else {
            model.loadJevKey()
            model.beginWakeListening()
            // Settings opens by itself only while setup is missing something, so a relaunch after an update stays quiet.
            Task {
                await model.speech.loadKey()
                let readiness = SetupReadiness(
                    hasKey: !model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    microphone: MicrophoneAccess(AVCaptureDevice.authorizationStatus(for: .audio)),
                    controlGranted: AXIsProcessTrusted())
                if readiness.missingCount > 0 { showSettings() }
            }
        }
    }

    private func runDemo(_ locale: AppModel.DemoLocale, arguments: [String]) {
        model.autoInsert = false
        model.apiKey = "demo-synthetic-key"
        if arguments.contains("--demo-settings") {
            model.accessibilityGranted = true
            model.microphoneAccessOverride = .granted
            showSettings()
            return
        }
        guard !arguments.contains("--demo-idle") else { return }
        if let id = Self.value(after: "--demo-screen", in: arguments).flatMap(UInt32.init) {
            let step = Self.value(after: "--demo-step-ms", in: arguments).flatMap(Int.init) ?? 450
            guard let recording = DemoRecording(model: model, locale: locale, screenID: id) else {
                print("DEMO_SCREEN_NOT_FOUND")
                exit(3)
            }
            demoRecording = recording
            recording.run(stepInterval: .milliseconds(step)) {
                print("DEMO_DONE")
                fflush(stdout)
                exit(0)
            }
            return
        }
        let delay = Self.value(after: "--demo-delay-ms", in: arguments).flatMap(Int.init) ?? 600
        let step = Self.value(after: "--demo-step-ms", in: arguments).flatMap(Int.init) ?? 220
        let hold = Self.value(after: "--demo-hold-ms", in: arguments).flatMap(Int.init) ?? 700
        Task {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            model.runDemo(locale, stepInterval: .milliseconds(step), holdBeforeFinish: .milliseconds(hold))
        }
    }

    private func transcribeFile(_ path: String, arguments: [String]) {
        model.autoInsert = !arguments.contains("--no-auto-insert")
        model.printsTurnsAndQuits = arguments.contains("--print-turns")
        // Diagnostics: another command judge, Soniox context terms ("" for none) or Jev key for this run only.
        if let mode = Self.value(after: "--command-judge", in: arguments).flatMap(CommandJudgeMode.init) {
            model.commandJudgeOverride = mode
        }
        if let list = Self.value(after: "--context-terms", in: arguments) {
            model.contextTermsOverride = DictionaryTerms.adding(list, to: [])
        }
        if let list = Self.value(after: "--add-context-terms", in: arguments) {
            model.addedContextTerms = DictionaryTerms.adding(list, to: [])
        }
        if let text = Self.value(after: "--context-text", in: arguments) { model.speech.contextText = text }
        if let file = Self.value(after: "--jev-key-file", in: arguments) {
            model.jevKeyOverride = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        } else {
            model.loadJevKey()
        }
        Task {
            await model.speech.loadKey()
            model.transcribeFile(URL(fileURLWithPath: path))
        }
    }
    /// Diagnostic: runs the bundled wake-phrase model over an audio file, with no window, microphone or network.
    /// Prints `WAKE <n>` per detection and `WAKE_TOTAL <n>` at the end, then quits.
    private static func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    private func checkWakePhrase(in file: URL, arguments: [String]) {
        let phrase = arguments.firstIndex(of: "--wake-phrase").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? model.wakePhrase
        let sensitivity = arguments.firstIndex(of: "--wake-sensitivity")
            .flatMap { arguments.indices.contains($0 + 1) ? WakeSensitivity(rawValue: arguments[$0 + 1]) : nil }
            ?? model.wakeSensitivity
        guard let modelURL = Bundle.main.url(forResource: "WakeWord", withExtension: nil),
              let listener = try? WakeWordListener(model: modelURL, audioFile: file,
                                                  realTime: arguments.contains("--wake-realtime")),
              let pieces = listener.tokenizer.pieces(for: phrase) else {
            print("WAKE_UNAVAILABLE")
            exit(2)
        }
        var heard = 0
        let launched = ContinuousClock.now
        listener.onWake = { [weak listener] in
            heard += 1
            // Milliseconds of audio fed before the phrase was heard, and how long listening took to start.
            let fed = listener?.feedingSince.map { ContinuousClock.now - $0 } ?? .zero
            let setup = (listener?.feedingSince ?? launched) - launched
            print("WAKE \(heard) at_ms=\(Int(fed / .milliseconds(1))) setup_ms=\(Int(setup / .milliseconds(1)))")
        }
        listener.onFailure = { _ in
            print("WAKE_TOTAL \(heard)")
            fflush(stdout)
            NSApp.terminate(nil)
        }
        wakeCheck = listener
        listener.start(pieces: pieces, sensitivity: sensitivity, deviceUID: nil,
                       spoken: arguments.contains("--wake-keyword-only") ? nil : AppModel.wakeMatcher(for: phrase))
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
