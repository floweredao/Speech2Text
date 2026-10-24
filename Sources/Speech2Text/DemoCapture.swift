import AppKit
import DictationSpeech
import SwiftUI

@MainActor
enum DemoCapturer {
    static let scale: CGFloat = 2
    static let expandedOverlayWidth: CGFloat = 480
    /// Ends on the row separator after Punctuation at the default text size, so the last row is not cut through.
    static func settingsSize(for locale: AppModel.DemoLocale) -> NSSize {
        NSSize(width: 480, height: locale == .en ? 787 : 745)
    }
    static let stageSize = NSSize(width: 640, height: 212)
    static let offscreenOrigin = NSPoint(x: -10_000, y: -10_000)

    static func captureAll(to directory: URL, locale: AppModel.DemoLocale, model: AppModel) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = locale.rawValue
        let targetIcon = rasterizedTargetIcon()
        let ready = String(localized: "받아쓰기 준비가 됐어요.")
        let listening = String(localized: "듣고 있어요.")
        let finished = String(localized: "받아쓰기를 마쳤어요.")
        let finalStep = locale.steps.last ?? ""

        model.configureForDemoCapture()
        model.speech.setDemoState(phase: .idle, transcript: "", status: ready)
        captureSettings(model: model, size: settingsSize(for: locale), appearanceName: .aqua,
                        to: directory.appendingPathComponent("settings-light-\(suffix).png"))
        captureSettings(model: model, size: settingsSize(for: locale), appearanceName: .darkAqua,
                        to: directory.appendingPathComponent("settings-dark-\(suffix).png"))

        model.configureForDemoCapture()
        model.speech.setDemoState(phase: .idle, transcript: "", status: ready)
        captureOverlay(model: model, width: NotchOverlayGeometry.compactWidth,
                       to: directory.appendingPathComponent("notch-idle-\(suffix).png"))

        model.configureForDemoCapture()
        model.seedDemoHistory(locale.history)
        model.configureDemoTarget(name: locale.targetName, icon: targetIcon)
        model.speech.setDemoState(phase: .recording, transcript: finalStep, status: listening, level: 0.62)
        captureOverlay(model: model, width: expandedOverlayWidth,
                       to: directory.appendingPathComponent("notch-recording-\(suffix).png"))

        model.configureForDemoCapture()
        model.seedDemoHistory([finalStep] + locale.history)
        model.feedback = String(localized: "받아쓰기를 보관했어요. 입력 칸을 선택한 뒤 붙여넣어 주세요.")
        model.speech.setDemoState(phase: .idle, transcript: finalStep, status: finished, outcome: .completed)
        captureOverlay(model: model, width: expandedOverlayWidth,
                       to: directory.appendingPathComponent("notch-result-\(suffix).png"))

        let frames = directory.appendingPathComponent("frames-\(suffix)", isDirectory: true)
        try? FileManager.default.removeItem(at: frames)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        var frameIndex = 0
        func stage() {
            captureStage(model: model, to: frames.appendingPathComponent(String(format: "frame-%03d.png", frameIndex)))
            frameIndex += 1
        }

        model.configureForDemoCapture()
        model.speech.setDemoState(phase: .idle, transcript: "", status: ready)
        for _ in 0..<6 { stage() }

        for (step, text) in locale.animationSteps.enumerated() {
            for sub in 0..<4 {
                let tick = Double(step * 4 + sub)
                model.configureForDemoCapture()
                model.seedDemoHistory(locale.history)
                model.configureDemoTarget(name: locale.targetName, icon: targetIcon)
                model.speech.setDemoState(phase: .recording, transcript: text, status: listening,
                                          level: Float(0.35 + 0.35 * abs(sin(tick * 0.9))))
                stage()
            }
        }

        let final = locale.animationSteps.last ?? ""
        model.configureForDemoCapture()
        model.seedDemoHistory([final] + locale.history)
        model.configureDemoTarget(name: locale.targetName, icon: targetIcon)
        model.setRoutineFeedback(String(localized: "입력 칸에 받아쓰기를 입력했어요."))
        model.speech.setDemoState(phase: .idle, transcript: final, status: finished, outcome: .completed)
        for _ in 0..<14 { stage() }
    }

    /// Rasterizes the Notes icon into a bitmap rep so offscreen rendering never hits the lazy NSWorkspace icon dimming bug.
    static func rasterizedTargetIcon() -> NSImage {
        let raw = NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app")
        let points = NSSize(width: OverlayTargetChip.iconSize, height: OverlayTargetChip.iconSize)
        let pixels = Int(points.width * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return raw }
        rep.size = points
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        raw.draw(in: NSRect(origin: .zero, size: points), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: points)
        image.addRepresentation(rep)
        return image
    }

    private static func overlayView(model: AppModel) -> some View {
        let presence = OverlayPresence()
        presence.shown = true
        return NotchOverlayView(model: model, presence: presence, onCancel: {}, onContentHeight: { _ in },
                                onDragChanged: { _ in }, onDragEnded: {})
    }

    private static func captureOverlay(model: AppModel, width: CGFloat, to url: URL) {
        let appearance = NSAppearance(named: .darkAqua)
        let window = borderlessWindow(size: NSSize(width: width, height: 400), appearance: appearance)
        let hosting = NSHostingView(rootView: overlayView(model: model).frame(width: width)
            .fixedSize(horizontal: false, vertical: true))
        hosting.appearance = appearance
        window.contentView = hosting
        var height = NotchOverlayGeometry.compactHeight
        for _ in 0..<3 {
            settle(hosting)
            let fitted = max(NotchOverlayGeometry.compactHeight, ceil(hosting.fittingSize.height))
            if fitted == height { break }
            height = fitted
            window.setContentSize(NSSize(width: width, height: height))
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        writePNG(from: hosting, size: NSSize(width: width, height: height), appearance: appearance, to: url)
    }

    /// The real titled window, never ordered in: its frame view draws the title bar around the Settings form.
    private static func captureSettings(model: AppModel, size: NSSize, appearanceName: NSAppearance.Name, to url: URL) {
        let appearance = NSAppearance(named: appearanceName)
        let window = NSWindow(contentRect: NSRect(origin: offscreenOrigin, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "말글")
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SettingsView(model: model).frame(width: size.width, height: size.height))
        hosting.appearance = appearance
        window.contentView = hosting
        giveKeyAppearance(window)
        settle(hosting)
        let frame = window.contentView?.superview ?? hosting
        writePNG(from: frame, size: frame.bounds.size, appearance: appearance, to: url)
    }

    /// A window that is not key draws inactive: gray title, gray switches with the knob still at the right, which a
    /// screenshot reader takes for "off". These undocumented AppKit methods give the unshown window the key look
    /// without activating the app, so no other app loses focus. They are skipped when AppKit no longer has them.
    private static func giveKeyAppearance(_ window: NSWindow) {
        for name in ["acquireKeyAppearance", "acquireMainAppearance"] {
            let selector = NSSelectorFromString(name)
            if window.responds(to: selector) { _ = window.perform(selector) }
        }
    }

    private static func captureStage(model: AppModel, to url: URL) {
        let appearance = NSAppearance(named: .darkAqua)
        let expanded = DictationDisplayState(model: model).isExpanded
        let width = expanded ? expandedOverlayWidth : NotchOverlayGeometry.compactWidth
        let root = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.20), Color(red: 0.11, green: 0.12, blue: 0.15)],
                           startPoint: .top, endPoint: .bottom)
            overlayView(model: model)
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.38), radius: 18, y: 8)
                .padding(.top, 20)
        }
        .frame(width: stageSize.width, height: stageSize.height)
        let window = borderlessWindow(size: stageSize, appearance: appearance)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance
        window.contentView = hosting
        settle(hosting)
        writePNG(from: hosting, size: stageSize, appearance: appearance, to: url)
    }

    private static func borderlessWindow(size: NSSize, appearance: NSAppearance?) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: offscreenOrigin, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        return window
    }

    /// SwiftUI measures text and reports geometry over several run loop turns before the layout holds still.
    private static func settle(_ hosting: NSView) {
        for _ in 0..<6 {
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        hosting.layoutSubtreeIfNeeded()
    }

    private static func writePNG(from view: NSView, size: NSSize, appearance: NSAppearance?, to url: URL) {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = size
        let bounds = NSRect(origin: .zero, size: size)
        if let appearance {
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: bounds, to: rep) }
        } else {
            view.cacheDisplay(in: bounds, to: rep)
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
