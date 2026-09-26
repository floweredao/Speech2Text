import AppKit
import DictationSpeech
import Observation
import SwiftUI

/// Typed facts about the latest run, reported by the engine. See DESIGN.md, "상태 모델".
struct DictationSession: Equatable {
    var outcome: SpeechOutcome = .none
    var hasCurrentTranscript = false

    func freshTranscript(_ transcript: String) -> String {
        hasCurrentTranscript ? transcript : ""
    }
}

/// Screen-facing state derived from the typed engine phase, error flag, and session outcome.
/// Status text is already localized by the engine and is only displayed, never parsed.
struct DictationDisplayState: Equatable {
    enum Phase: Equatable { case idle, connecting, recording, finalizing, result, notice, cancelled, error }
    enum Action: Hashable { case start, finish, cancel, settings, dismiss }
    /// Why retained text is not the current result.
    enum RetainedKind: Equatable { case previous, unfinished }

    let phase: Phase
    let title: String
    /// Error explanation shown as the body of the error state; empty otherwise.
    let message: String
    /// Text from the latest run, shown as the main body.
    let transcript: String
    /// Older or unconfirmed text, shown only in a labelled secondary line.
    let retained: String
    let retainedKind: RetainedKind?
    let noteText: String

    @MainActor init(model: AppModel) {
        self.init(speechPhase: model.speechPhase, hasError: model.hasError, status: model.status,
                  transcript: model.transcript, feedback: model.feedback,
                  session: DictationSession(outcome: model.speechOutcome,
                                            hasCurrentTranscript: model.hasCurrentTranscript),
                  toggleShortcut: model.shortcuts[.toggleDictation]?.label)
    }

    init(speechPhase: SpeechPhase, hasError: Bool, status: String, transcript: String, feedback: String,
         session: DictationSession = DictationSession(), toggleShortcut: String? = "⌃⌥D") {
        let fresh = session.freshTranscript(transcript)
        let phase: Phase
        switch speechPhase {
        case .preparing: phase = .connecting
        case .recording: phase = .recording
        case .finishing: phase = .finalizing
        case .idle:
            if hasError { phase = .error }
            else if session.outcome == .cancelled { phase = .cancelled }
            else if !fresh.isEmpty { phase = .result }
            else if feedback.isEmpty && transcript.isEmpty { phase = .idle }
            else { phase = .notice }
        }
        self.phase = phase
        switch phase {
        case .idle: title = toggleShortcut.map { String(localized: "\($0) 눌러 받아쓰기") } ?? String(localized: "받아쓰기")
        case .error: title = String(localized: "받아쓰기 오류")
        default: title = status
        }
        message = phase == .error ? status : ""
        switch phase {
        case .recording, .finalizing, .result: self.transcript = fresh
        default: self.transcript = ""
        }
        let retained: String
        let kind: RetainedKind?
        switch phase {
        case .error:
            retained = transcript
            kind = session.outcome == .failed && !fresh.isEmpty ? .unfinished : .previous
        case .notice:
            retained = transcript
            kind = .previous
        case .cancelled:
            // Unconfirmed text heard before cancelling is never offered for copy or paste.
            retained = fresh.isEmpty ? transcript : ""
            kind = .previous
        default:
            retained = ""
            kind = nil
        }
        self.retained = retained
        retainedKind = retained.isEmpty ? nil : kind
        noteText = phase == .idle || phase == .error ? "" : feedback
    }

    var isBusy: Bool { phase == .connecting || phase == .finalizing }
    var followsTail: Bool { phase == .recording || phase == .finalizing }
    var isExpanded: Bool { !message.isEmpty || !transcript.isEmpty || !retained.isEmpty || !noteText.isEmpty }
    /// Copy and paste act on `model.transcript`, which is the shown body or retained line in these states.
    var offersTranscriptActions: Bool { phase == .result || !retained.isEmpty }

    var headerActions: [Action] {
        switch phase {
        case .connecting, .finalizing: [.cancel]
        case .recording: [.finish, .cancel]
        case .error: [.dismiss]
        case .idle, .result, .notice, .cancelled: [.start, .settings, .dismiss]
        }
    }

    /// Recovery actions shown as labelled buttons below an error message.
    var recoveryActions: [Action] { phase == .error ? [.start, .settings] : [] }

    var symbol: String {
        switch phase {
        case .idle, .connecting, .finalizing: "mic.fill"
        case .recording: "circle.fill"
        case .result: "checkmark.circle.fill"
        case .notice: "info.circle.fill"
        case .cancelled: "stop.circle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }
}

enum NotchOverlayGeometry {
    static let compactHeight: CGFloat = 44
    static let compactWidth: CGFloat = 340
    /// About five lines of 14 pt transcript text; longer text scrolls.
    static let maxTranscriptHeight: CGFloat = 96
    static let topGap: CGFloat = 8
    static let margin: CGFloat = 12

    static func width(screenWidth: CGFloat, expanded: Bool) -> CGFloat {
        let preferred = expanded ? min(max(screenWidth * 0.3, 420), 520) : compactWidth
        return min(preferred, max(0, screenWidth - margin * 2))
    }

    static func transcriptViewportHeight(textHeight: CGFloat) -> CGFloat {
        min(max(textHeight, 0), maxTranscriptHeight)
    }

    /// Horizontally centered below the notch, auxiliary top areas, or menu bar of `screen`.
    /// The top edge is fixed; the panel grows downward to the measured content height.
    static func frame(screen: CGRect, visible: CGRect, safeTop: CGFloat, auxiliaryTop: CGFloat = 0,
                      expanded: Bool, contentHeight: CGFloat) -> CGRect {
        let width = width(screenWidth: screen.width, expanded: expanded)
        let topInset = max(safeTop, auxiliaryTop, screen.maxY - visible.maxY)
        let available = max(0, screen.height - topInset - topGap - margin)
        let wanted = expanded ? max(contentHeight, compactHeight) : compactHeight
        let height = min(wanted, available)
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - topInset - topGap - height,
                      width: width, height: height)
    }

    /// Where the user dragged the panel: `anchor` is its top-center point. The top edge stays at the
    /// anchor while the height changes, and the frame is kept inside `screen`.
    static func frame(anchor: CGPoint, screen: CGRect, expanded: Bool, contentHeight: CGFloat) -> CGRect {
        let width = width(screenWidth: screen.width, expanded: expanded)
        let wanted = expanded ? max(contentHeight, compactHeight) : compactHeight
        let height = min(wanted, screen.height)
        let x = min(max(anchor.x - width / 2, screen.minX), screen.maxX - width)
        let top = min(max(anchor.y, screen.minY + height), screen.maxY)
        return CGRect(x: x, y: top - height, width: width, height: height)
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
    private var contentHeight = NotchOverlayGeometry.compactHeight
    private var announcedPhase: DictationDisplayState.Phase?
    /// Top-center point the user dragged the panel to. Kept in memory only, so a relaunch starts
    /// at the default position below the notch.
    private var userAnchor: CGPoint?
    /// Pointer and anchor, in screen coordinates, where the current drag began.
    private var dragStart: (mouse: CGPoint, anchor: CGPoint)?

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
        let state = DictationDisplayState(model: model)
        guard model.overlayVisible else {
            panel?.orderOut(nil)
            announcedPhase = nil
            dragStart = nil
            return
        }
        let resized = expanded != state.isExpanded
        expanded = state.isExpanded
        show(animateResize: resized)
        announce(state)
    }

    private func cancelDictation() {
        model.cancel()
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        guard let panel, panel.isVisible else { return }
        place(panel, animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func announce(_ state: DictationDisplayState) {
        guard announcedPhase != state.phase else { return }
        let first = announcedPhase == nil
        announcedPhase = state.phase
        guard !first || state.phase != .idle else { return }
        let text = state.phase == .error ? "\(state.title). \(state.message)" : state.title
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
            let view = NotchOverlayView(
                model: model,
                onCancel: { [weak self] in self?.cancelDictation() },
                onContentHeight: { [weak self] height in
                    // Resize after the current SwiftUI layout pass, never inside it.
                    Task { @MainActor [weak self] in self?.contentHeightChanged(height) }
                },
                onDragChanged: { [weak self] translation in self?.dragChanged(translation) },
                onDragEnded: { [weak self] in self?.dragStart = nil })
            let hosting = FirstClickHostingView(rootView: view)
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

    /// Moves the panel with the pointer. Screen coordinates are used because the view's own
    /// coordinate space moves with the panel; only the first translation predates any move.
    private func dragChanged(_ translation: CGSize) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (mouse: CGPoint(x: mouse.x - translation.width, y: mouse.y + translation.height),
                                  anchor: CGPoint(x: panel.frame.midX, y: panel.frame.maxY))
        dragStart = start
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? selectedScreen
        else { return }
        let wanted = CGPoint(x: start.anchor.x + mouse.x - start.mouse.x, y: start.anchor.y + mouse.y - start.mouse.y)
        let frame = NotchOverlayGeometry.frame(anchor: wanted, screen: screen.frame, expanded: expanded,
                                               contentHeight: contentHeight)
        userAnchor = CGPoint(x: frame.midX, y: frame.maxY)
        place(panel, animated: false)
    }

    private func place(_ panel: NSPanel, animated: Bool) {
        let frame: CGRect
        // The point just below the anchor decides its display; the top edge itself is outside `frame`.
        if let anchor = userAnchor,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: anchor.x, y: anchor.y - 1)) }) {
            selectedScreen = screen
            frame = NotchOverlayGeometry.frame(anchor: anchor, screen: screen.frame, expanded: expanded,
                                               contentHeight: contentHeight)
        } else {
            // The dragged-to display is gone: fall back to the default position.
            userAnchor = nil
            let screen = selectedScreen.flatMap { selected in NSScreen.screens.first { $0 == selected } }
                ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen else { return }
            selectedScreen = screen
            let auxiliaryTop = max(screen.auxiliaryTopLeftArea?.height ?? 0,
                                   screen.auxiliaryTopRightArea?.height ?? 0)
            frame = NotchOverlayGeometry.frame(screen: screen.frame, visible: screen.visibleFrame,
                                               safeTop: screen.safeAreaInsets.top,
                                               auxiliaryTop: auxiliaryTop, expanded: expanded,
                                               contentHeight: contentHeight)
        }
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
    let onCancel: () -> Void
    let onContentHeight: (CGFloat) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let state = DictationDisplayState(model: model)
        let shape = RoundedRectangle(cornerRadius: state.isExpanded ? 18 : NotchOverlayGeometry.compactHeight / 2,
                                     style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            header(state)
            if state.isExpanded { details(state) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, state.isExpanded ? 12 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Content decides the height; the controller sizes the panel to this measurement.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(white: 0.11), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.7 : 0.12), lineWidth: 1))
        .clipShape(shape)
        // Drag anywhere outside the buttons to move the panel; buttons keep their clicks.
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { onDragChanged($0.translation) }
            .onEnded { _ in onDragEnded() })
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onContentHeight($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            HStack(spacing: 6) {
                ForEach(state.headerActions, id: \.self) { action in
                    OverlayIconButton(symbol: symbol(for: action), label: label(for: action, state),
                                      id: identifier(for: action), prominent: action == .start) {
                        perform(action)
                    }
                }
            }
        }
        .frame(height: 28)
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
    private func details(_ state: DictationDisplayState) -> some View {
        if !state.message.isEmpty {
            Text(state.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.orange)
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(state.message)
                .accessibilityIdentifier("notch-error")
        }
        if !state.recoveryActions.isEmpty {
            HStack(spacing: 8) {
                ForEach(state.recoveryActions, id: \.self) { action in
                    OverlayTextButton(title: action == .start ? String(localized: "다시 시도") + shortcutSuffix(.toggleDictation) : String(localized: "설정 확인"),
                                      symbol: action == .start ? "arrow.clockwise" : "gearshape",
                                      id: action == .start ? "notch-retry" : "notch-open-settings") {
                        perform(action)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        if !state.transcript.isEmpty {
            TranscriptViewport(text: state.transcript, followsTail: state.followsTail)
        }
        if !state.noteText.isEmpty {
            Text(state.noteText)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.68))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(state.noteText)
                .accessibilityIdentifier("notch-feedback")
        }
        if let kind = state.retainedKind {
            retainedLine(state.retained, kind: kind)
        } else if state.offersTranscriptActions {
            HStack(spacing: 8) {
                OverlayTextButton(title: String(localized: "복사"), symbol: "doc.on.doc", id: "notch-copy") { model.copyTranscript() }
                OverlayTextButton(title: String(localized: "붙여넣기") + shortcutSuffix(.pasteTranscript), symbol: "arrow.down.doc",
                                  id: "notch-paste") {
                    model.pasteTranscript()
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Older or unconfirmed text: labelled, dimmed, one line, with compact copy and paste.
    private func retainedLine(_ text: String, kind: DictationDisplayState.RetainedKind) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(kind == .previous ? String(localized: "이전 받아쓰기") : String(localized: "중단 전 받은 텍스트 · 확정 아님"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notch-retained")
            OverlayIconButton(symbol: "doc.on.doc", label: String(localized: "복사"), id: "notch-copy", prominent: false) {
                model.copyTranscript()
            }
            OverlayIconButton(symbol: "arrow.down.doc", label: String(localized: "붙여넣기") + shortcutHint(.pasteTranscript), id: "notch-paste",
                              prominent: false) {
                model.pasteTranscript()
            }
        }
        .padding(.top, 2)
    }

    private func perform(_ action: DictationDisplayState.Action) {
        switch action {
        case .start, .finish: model.toggleRecording()
        case .cancel: onCancel()
        case .settings: model.openSettings()
        case .dismiss: model.dismissOverlay()
        }
    }

    private func symbol(for action: DictationDisplayState.Action) -> String {
        switch action {
        case .start: "mic.fill"
        case .finish: "stop.fill"
        case .cancel, .dismiss: "xmark"
        case .settings: "gearshape"
        }
    }

    private func label(for action: DictationDisplayState.Action, _ state: DictationDisplayState) -> String {
        switch action {
        case .start: String(localized: "받아쓰기 시작") + shortcutHint(.toggleDictation)
        case .finish: String(localized: "녹음 마치기") + shortcutHint(.toggleDictation)
        case .cancel: state.phase == .recording ? String(localized: "녹음 취소") : String(localized: "받아쓰기 취소")
        case .settings: String(localized: "설정 열기")
        case .dismiss: String(localized: "닫기")
        }
    }

    private func shortcutSuffix(_ action: ShortcutAction) -> String {
        model.shortcuts[action].map { " \($0.label)" } ?? ""
    }

    private func shortcutHint(_ action: ShortcutAction) -> String {
        model.shortcuts[action].map { " (\($0.label))" } ?? ""
    }

    private func identifier(for action: DictationDisplayState.Action) -> String {
        switch action {
        case .start: "notch-start"
        case .finish: "notch-finish"
        case .cancel: "notch-cancel"
        case .settings: "notch-settings"
        case .dismiss: "notch-dismiss"
        }
    }
}

/// Scrolls only when the measured text exceeds the viewport, so short text leaves no gutter.
private struct TranscriptViewport: View {
    let text: String
    let followsTail: Bool
    /// `State` struct instead of the `@State` macro: the CLT toolchain ships no SwiftUIMacros plugin.
    private let textHeight = State(initialValue: CGFloat(19))

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight.wrappedValue = $0 }
                .accessibilityIdentifier("notch-transcript")
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .defaultScrollAnchor(followsTail ? .bottom : .top)
        .defaultScrollAnchor(followsTail ? .bottom : .top, for: .sizeChanges)
        .frame(height: NotchOverlayGeometry.transcriptViewportHeight(textHeight: textHeight.wrappedValue))
    }
}

private struct OverlayIconButton: View {
    let symbol: String
    let label: String
    let id: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(OverlayControlStyle(shape: .circle, prominent: prominent))
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
        .buttonStyle(OverlayControlStyle(shape: .capsule, prominent: false))
        .help(title)
        .accessibilityIdentifier(id)
    }
}

private struct OverlayControlStyle: ButtonStyle {
    enum Shape { case circle, capsule }
    let shape: Shape
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed || prominent ? 1 : 0.78))
        let base = prominent ? 0.18 : 0.08
        let fill = Color.white.opacity(configuration.isPressed ? 0.26 : base)
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
