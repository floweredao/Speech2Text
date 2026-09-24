import AppKit
import DictationSpeech
import Observation
import SwiftUI

/// Screen-facing state derived from the typed engine phase and error flag. Status text is
/// already localized by the engine and is only displayed, never parsed. See DESIGN.md, "상태 모델".
struct DictationDisplayState: Equatable {
    enum Phase: Equatable { case idle, connecting, recording, finalizing, result, notice, error }

    let phase: Phase
    let title: String
    let bodyText: String
    let noteText: String

    @MainActor init(model: AppModel) {
        self.init(speechPhase: model.speechPhase, hasError: model.hasError, status: model.status,
                  transcript: model.transcript, feedback: model.feedback)
    }

    init(speechPhase: SpeechPhase, hasError: Bool, status: String, transcript: String, feedback: String) {
        let phase: Phase
        switch speechPhase {
        case .preparing: phase = .connecting
        case .recording: phase = .recording
        case .finishing: phase = .finalizing
        case .idle:
            if hasError { phase = .error }
            else if !transcript.isEmpty { phase = .result }
            else if feedback.isEmpty { phase = .idle }
            else { phase = .notice }
        }
        self.phase = phase
        switch phase {
        case .idle: title = "⌃⌥D로 받아쓰기"
        case .error: title = "받아쓰기 오류"
        case .connecting, .recording, .finalizing, .result, .notice: title = status
        }
        bodyText = transcript.isEmpty ? (phase == .error ? status : "") : transcript
        noteText = phase == .error && !transcript.isEmpty ? status : feedback
    }

    var isExpanded: Bool { !bodyText.isEmpty || !noteText.isEmpty }
    var isBusy: Bool { phase == .connecting || phase == .finalizing }

    var symbol: String {
        switch phase {
        case .idle, .connecting, .finalizing: "mic.fill"
        case .recording: "circle.fill"
        case .result: "checkmark.circle.fill"
        case .notice: "info.circle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }
}

struct NotchOverlayGeometry {
    static let compactHeight: CGFloat = 44
    static let expandedHeight: CGFloat = 196

    /// Horizontally centered below the notch, auxiliary top areas, or menu bar of `screen`.
    static func frame(screen: CGRect, visible: CGRect, safeTop: CGFloat,
                      auxiliaryTop: CGFloat = 0, expanded: Bool) -> CGRect {
        let margin: CGFloat = 12
        let width = min(max(screen.width * 0.3, 400), 560, max(0, screen.width - margin * 2))
        let topInset = max(safeTop, auxiliaryTop, screen.maxY - visible.maxY)
        let wanted = expanded ? expandedHeight : compactHeight
        let height = min(wanted, max(0, screen.height - topInset - margin * 2))
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - topInset - 8 - height,
                      width: width, height: height)
    }
}

/// Never key or main: the dictation target keeps keyboard focus while the overlay is visible.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons respond to the first click without activating Speech2Text.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchOverlayController: NSObject {
    private let model: AppModel
    private var panel: OverlayPanel?
    private var running = false
    private var observationGeneration = UUID()
    private var selectedScreen: NSScreen?
    private var expanded = false
    private var announcedPhase: DictationDisplayState.Phase?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func start() {
        guard !running else { return }
        running = true
        observationGeneration = UUID()
        NotificationCenter.default.addObserver(self, selector: #selector(reposition),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reposition),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        observe()
    }

    /// Shows the overlay on the display under the pointer. Never activates the app.
    func present() {
        guard running else { return }
        selectedScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        model.overlayVisible = true
        show()
    }

    func stop() {
        running = false
        observationGeneration = UUID()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel?.orderOut(nil)
        panel = nil
    }

    private func observe() {
        guard running else { return }
        let generation = observationGeneration
        withObservationTracking {
            synchronize()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.running, self.observationGeneration == generation else { return }
                self.observe()
            }
        }
    }

    /// No hide timer: a result stays until the user dismisses it or a new dictation replaces it.
    private func synchronize() {
        let visible = model.overlayVisible
        let state = DictationDisplayState(model: model)
        guard visible else {
            panel?.orderOut(nil)
            announcedPhase = nil
            return
        }
        let resized = expanded != state.isExpanded
        expanded = state.isExpanded
        show(animateResize: resized)
        announce(state)
    }

    private func announce(_ state: DictationDisplayState) {
        guard announcedPhase != state.phase else { return }
        let first = announcedPhase == nil
        announcedPhase = state.phase
        guard !first || state.phase != .idle else { return }
        let text = state.phase == .error ? "\(state.title). \(state.bodyText)" : state.title
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func show(animateResize: Bool = false) {
        if panel == nil {
            let window = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.becomesKeyOnlyIfNeeded = true
            window.animationBehavior = .none
            let hosting = FirstClickHostingView(rootView: NotchOverlayView(model: model))
            hosting.sizingOptions = []
            window.contentView = hosting
            panel = window
        }
        guard let panel else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        place(panel, animated: animateResize && panel.isVisible && !reduceMotion)
        guard !panel.isVisible else { return }
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
    }

    @objc private func reposition() {
        guard let panel else { return }
        place(panel, animated: false)
    }

    private func place(_ panel: NSPanel, animated: Bool) {
        let screen = selectedScreen.flatMap { selected in NSScreen.screens.first { $0 == selected } }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        selectedScreen = screen
        let auxiliaryTop = max(screen.auxiliaryTopLeftArea?.height ?? 0,
                               screen.auxiliaryTopRightArea?.height ?? 0)
        let frame = NotchOverlayGeometry.frame(screen: screen.frame, visible: screen.visibleFrame,
                                               safeTop: screen.safeAreaInsets.top,
                                               auxiliaryTop: auxiliaryTop, expanded: expanded)
        guard panel.frame != frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

private struct NotchOverlayView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let state = DictationDisplayState(model: model)
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            header(state)
            if state.isExpanded { details(state) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, state.isExpanded ? 12 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.11), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.7 : 0.12), lineWidth: 1))
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("받아쓰기")
        .accessibilityIdentifier("notch-overlay")
    }

    private func header(_ state: DictationDisplayState) -> some View {
        HStack(spacing: 10) {
            indicator(state)
                .frame(width: 20, height: 20)
            Text(state.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(state.title)
                .accessibilityIdentifier("notch-status")
            controls(state)
        }
        .frame(height: state.isExpanded ? 28 : NotchOverlayGeometry.compactHeight)
    }

    @ViewBuilder
    private func indicator(_ state: DictationDisplayState) -> some View {
        Group {
            if state.isBusy {
                ProgressView().controlSize(.small).tint(.white)
            } else if state.phase == .recording {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.red)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            } else {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.phase == .error ? Color.orange : Color.white.opacity(0.82))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(state.title)
    }

    @ViewBuilder
    private func controls(_ state: DictationDisplayState) -> some View {
        HStack(spacing: 6) {
            switch state.phase {
            case .recording:
                OverlayIconButton(symbol: "stop.fill", label: "녹음 마치기 (⌃⌥D)", id: "notch-finish") {
                    model.toggleRecording()
                }
                OverlayIconButton(symbol: "xmark", label: "녹음 취소", id: "notch-cancel") { model.cancel() }
            case .connecting, .finalizing:
                OverlayIconButton(symbol: "xmark", label: "받아쓰기 취소", id: "notch-cancel") { model.cancel() }
            case .idle, .notice, .error:
                OverlayIconButton(symbol: "gearshape", label: "설정 열기", id: "notch-settings") {
                    model.openSettings()
                }
                OverlayIconButton(symbol: "xmark", label: "닫기", id: "notch-dismiss") { model.dismissOverlay() }
            case .result:
                OverlayIconButton(symbol: "xmark", label: "닫기", id: "notch-dismiss") { model.dismissOverlay() }
            }
        }
    }

    @ViewBuilder
    private func details(_ state: DictationDisplayState) -> some View {
        if !state.bodyText.isEmpty {
            ScrollView(.vertical) {
                Text(state.bodyText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(state.phase == .error && model.transcript.isEmpty ? Color.orange : .white)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notch-transcript")
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
        } else {
            Spacer(minLength: 0)
        }
        if !state.noteText.isEmpty {
            Text(state.noteText)
                .font(.system(size: 11))
                .foregroundStyle(state.phase == .error ? Color.orange : Color.white.opacity(0.68))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(state.noteText)
                .accessibilityIdentifier("notch-feedback")
        }
        if state.phase == .result || (!model.transcript.isEmpty && (state.phase == .notice || state.phase == .error)) {
            HStack(spacing: 8) {
                OverlayTextButton(title: "복사", symbol: "doc.on.doc", id: "notch-copy") { model.copyTranscript() }
                OverlayTextButton(title: "붙여넣기 ⌃⌥V", symbol: "arrow.down.doc", id: "notch-paste") {
                    model.pasteTranscript()
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct OverlayIconButton: View {
    let symbol: String
    let label: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(OverlayControlStyle(shape: .circle))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

private struct OverlayTextButton: View {
    let title: String
    let symbol: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(OverlayControlStyle(shape: .capsule))
        .help(title)
        .accessibilityIdentifier(id)
    }
}

private struct OverlayControlStyle: ButtonStyle {
    enum Shape { case circle, capsule }
    let shape: Shape

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 1 : 0.78))
        let fill = Color.white.opacity(configuration.isPressed ? 0.22 : 0.08)
        return Group {
            switch shape {
            case .circle:
                label.frame(width: 24, height: 24)
                    .background(fill, in: Circle())
                    .contentShape(Circle())
            case .capsule:
                label.padding(.horizontal, 10).frame(height: 26)
                    .background(fill, in: Capsule())
                    .contentShape(Capsule())
            }
        }
    }
}
