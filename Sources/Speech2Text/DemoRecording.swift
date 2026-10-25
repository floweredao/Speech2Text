import AppKit

/// The scripted flow `scripts/record-demo-video.sh` films for the README: a key cap for the shortcut, the real overlay
/// listening, the words appearing in a plain note window as they are recognized, and the finished result. Everything
/// lives on one display (`--demo-screen`), normally a virtual one, and uses synthetic text only: no microphone,
/// network or other app is involved, and the app quits when the flow ends.
@MainActor
final class DemoRecording {
    private let model: AppModel
    private let locale: AppModel.DemoLocale
    private let screen: NSScreen
    private var note: NSWindow?
    private var noteText: NSTextView?
    private var keyCap: NSPanel?
    private var follow: Timer?

    init?(model: AppModel, locale: AppModel.DemoLocale, screenID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == screenID
        }) else { return nil }
        self.model = model
        self.locale = locale
        self.screen = screen
    }

    func run(stepInterval: Duration, done: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            showNote()
            try? await Task.sleep(for: .milliseconds(900))
            showKeyCap()
            try? await Task.sleep(for: .milliseconds(350))
            let typing = model.runDemo(locale, stepInterval: stepInterval, holdBeforeFinish: .milliseconds(900))
            startFollowing()
            try? await Task.sleep(for: .milliseconds(650))
            hideKeyCap()
            await typing?.value
            follow?.invalidate()
            noteText?.string = model.speech.transcript
            try? await Task.sleep(for: .milliseconds(3200))
            done()
        }
    }

    private func showNote() {
        let size = NSSize(width: 760, height: 220)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - 200 - size.height,
                           width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false, screen: screen)
        window.title = locale == .ko ? "메모" : "Notes"
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        let text = NSTextView(frame: scroll.bounds)
        text.font = .systemFont(ofSize: 22)
        text.textContainerInset = NSSize(width: 22, height: 22)
        text.isEditable = false
        text.string = ""
        scroll.documentView = text
        scroll.hasVerticalScroller = false
        window.contentView = scroll
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        note = window
        noteText = text
    }

    private func startFollowing() {
        follow = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let text = self.noteText else { return }
                let current = self.model.speech.transcript
                if text.string != current { text.string = current }
            }
        }
    }

    private func showKeyCap() {
        let size = NSSize(width: 230, height: 92)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - 450 - size.height,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false, screen: screen)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        let back = NSView(frame: NSRect(origin: .zero, size: size))
        back.wantsLayer = true
        back.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        back.layer?.cornerRadius = 22
        let label = NSTextField(labelWithString: "⌃ ⌥ D")
        label.font = .systemFont(ofSize: 42, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (size.height - 54) / 2, width: size.width, height: 54)
        back.addSubview(label)
        panel.contentView = back
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        keyCap = panel
    }

    private func hideKeyCap() {
        guard let panel = keyCap else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
        keyCap = nil
    }
}
