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
    enum Action: Hashable { case start, finish, cancel, settings, dismiss, copy }
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
    /// The error comes from setup (key, microphone, permission), so retrying without a change repeats it.
    let needsSettings: Bool
    /// Earlier dictations below the current one, newest first. Never includes the text shown as the body or the
    /// labelled retained line.
    let history: [DictationRecord]
    /// Older records behind the "more" button; offered only while no dictation runs.
    let moreHistory: [DictationRecord]
    /// The app live typing writes into, shown quietly beside the title while it matters.
    let targetName: String?
    /// The result already went into the field, so copy and paste step back to one header button.
    let inserted: Bool
    /// Words Soniox was unsure of, marked in the transcript when the setting is on.
    let uncertainWords: [String]

    @MainActor init(model: AppModel) {
        self.init(speechPhase: model.speechPhase, hasError: model.hasError, needsSettings: model.needsSettings,
                  status: model.status,
                  transcript: model.transcript, feedback: model.feedback,
                  session: DictationSession(outcome: model.speechOutcome,
                                            hasCurrentTranscript: model.hasCurrentTranscript),
                  toggleShortcut: model.shortcuts[.toggleDictation]?.label, history: model.history,
                  feedbackIsRoutine: model.feedbackIsRoutine, targetName: model.liveTargetName,
                  uncertainWords: model.uncertainWords)
    }

    init(speechPhase: SpeechPhase, hasError: Bool, needsSettings: Bool = false, status: String, transcript: String,
         feedback: String, session: DictationSession = DictationSession(), toggleShortcut: String? = "⌃⌥D",
         history: [DictationRecord] = [], feedbackIsRoutine: Bool = false, targetName: String? = nil,
         uncertainWords: [String] = []) {
        self.needsSettings = needsSettings
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
        // Routine confirmations (typing live, typed in) would only compete with the transcript; problems stay.
        noteText = phase == .idle || phase == .error || feedbackIsRoutine ? "" : feedback
        inserted = phase == .result && feedbackIsRoutine
        self.targetName = phase == .recording || phase == .finalizing || inserted ? targetName : nil
        self.uncertainWords = uncertainWords
        // The newest record is the finished result itself, or the "previous" line, until a new dictation starts.
        let older: ArraySlice<DictationRecord>
        switch phase {
        case .idle: older = []
        case .result: older = history.dropFirst()
        default: older = retainedKind == .previous ? history.dropFirst() : history[...]
        }
        self.history = Array(older.prefix(NotchOverlayGeometry.historyRows))
        let dictating = phase == .connecting || phase == .recording || phase == .finalizing
        moreHistory = dictating ? [] : Array(older.dropFirst(NotchOverlayGeometry.historyRows))
    }

    /// What changes the overlay's layout, so motion follows these changes but not every revision of live text.
    struct LayoutKey: Hashable {
        let phase: Phase
        let history: [UUID]
        let hasTranscript: Bool
        let hasNote: Bool
        let hasTarget: Bool
    }
    var layoutKey: LayoutKey {
        LayoutKey(phase: phase, history: history.map(\.id), hasTranscript: !transcript.isEmpty, hasNote: !noteText.isEmpty,
                  hasTarget: targetName != nil)
    }

    var isBusy: Bool { phase == .connecting || phase == .finalizing }
    var isDictating: Bool { phase == .connecting || phase == .recording || phase == .finalizing }
    var followsTail: Bool { phase == .recording || phase == .finalizing }
    var isExpanded: Bool {
        !message.isEmpty || !transcript.isEmpty || !retained.isEmpty || !noteText.isEmpty || !history.isEmpty
    }
    /// Copy and paste act on `model.transcript`, which is the shown body or retained line in these states.
    var offersTranscriptActions: Bool { phase == .result || !retained.isEmpty }

    var headerActions: [Action] {
        switch phase {
        case .connecting, .finalizing: [.cancel]
        case .recording: [.finish, .cancel]
        case .error: [.dismiss]
        case .result where inserted: [.copy, .start, .settings, .dismiss]
        case .idle, .result, .notice, .cancelled: [.start, .settings, .dismiss]
        }
    }

    /// Recovery actions shown as labelled buttons below an error message.
    var recoveryActions: [Action] {
        guard phase == .error else { return [] }
        return needsSettings ? [.settings] : [.start, .settings]
    }

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
    /// The transcript grows to this many lines of its text style, then scrolls. The view measures the lines,
    /// so the cap follows the system text size.
    static let maxTranscriptLines = 5
    /// Earlier dictations shown under the current one; older ones stay in `AppModel.history`.
    static let historyRows = 1
    /// Used only until the five-line sample has been measured.
    static let fallbackMaxTranscriptHeight: CGFloat = 96
    /// Smallest hit area of an overlay button, whatever its visible size.
    static let minimumHitSize: CGFloat = 28
    static let topGap: CGFloat = 8
    static let margin: CGFloat = 12
    /// Status indicator size. The capsule's side inset equals its top inset to the indicator, (44 - 28) / 2 + 4 = 12,
    /// so the indicator sits concentric with the rounded end.
    static let indicatorSize: CGFloat = 20
    static let sideInset: CGFloat = 12
    static let verticalInset: CGFloat = 8
    static let rowHeight: CGFloat = 28

    static func width(screenWidth: CGFloat, expanded: Bool) -> CGFloat {
        let preferred = expanded ? min(max(screenWidth * 0.3, 420), 520) : compactWidth
        return min(preferred, max(0, screenWidth - margin * 2))
    }

    static func transcriptViewportHeight(textHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        min(max(textHeight, 0), maxHeight)
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

    /// Where the user dragged the panel: `anchor` is its top-left corner, so the panel comes back where the
    /// user left it even when it reopens narrower or wider. It grows right and down; the frame stays in `screen`.
    static func frame(anchor: CGPoint, screen: CGRect, expanded: Bool, contentHeight: CGFloat) -> CGRect {
        let width = width(screenWidth: screen.width, expanded: expanded)
        let wanted = expanded ? max(contentHeight, compactHeight) : compactHeight
        let height = min(wanted, screen.height)
        let x = min(max(anchor.x, screen.minX), screen.maxX - width)
        let top = min(max(anchor.y, screen.minY + height), screen.maxY)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}

/// Spacing scale shared by the overlay and Settings: multiples of 4, with 2 only for hairline gaps.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
}

/// Motion values for the overlay and Settings. See DESIGN.md, "모션".
enum OverlayMotion {
    /// The panel frame (AppKit) and the content inside it (SwiftUI) share one curve and duration, so the surface
    /// and what it holds move together: a strong ease-out, quick while the user watches and soft as it settles.
    static let duration = 0.24
    static var resizeCurve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1) }
    static let layout = Animation.timingCurve(0.23, 1, 0.32, 1, duration: duration)
    /// Critically damped: nothing the user threw is moving, so it settles without overshoot. A spring starts
    /// from where the panel is, so showing it again during its exit turns around without a jump.
    static let appear = Animation.spring(duration: duration, bounce: 0)
    /// Leaves a little faster than it came, still easing out; ease-in would hold still while the user watches.
    static let disappear = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
    /// Pressing a control answers at once and comes back without a bounce.
    static let press = Animation.spring(duration: 0.12, bounce: 0)
    static let pressedScale: CGFloat = 0.96
    /// Live words settle into place instead of popping in.
    static let liveText = Animation.smooth(duration: 0.2)
    /// The level meter follows the voice closely without wobbling past it.
    static let meter = Animation.smooth(duration: 0.12)
    /// Reduce Motion keeps only a short cross-fade.
    static let reduced = Animation.easeOut(duration: 0.15)
    /// The entrance grows out of the notch: slightly smaller and higher, anchored at the top edge.
    static let hiddenScale: CGFloat = 0.94
    static let hiddenOffset: CGFloat = -6
    /// Each step down the history list is dimmer and a little smaller.
    static func historyOpacity(depth: Int) -> Double { max(0.38, 0.72 - Double(depth) * 0.14) }
    /// Smaller by one system text style per step, so the sizes still follow the user's text size.
    static func historyFont(depth: Int) -> Font { [Font.callout, .subheadline, .footnote][min(max(depth, 0), 2)] }
}

/// Runs an action once a time limit passes without another `restart`.
@MainActor final class IdleCountdown {
    private var task: Task<Void, Never>?

    func restart(after limit: Duration, _ action: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task {
            do { try await Task.sleep(for: limit) } catch { return }
            action()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Whether the overlay is shown or on its way out; the view animates its entrance and exit from it.
@MainActor @Observable final class OverlayPresence {
    var shown = false
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
    private var hosting: NSView?
    private let presence = OverlayPresence()
    /// Bumped by every show and hide, so an exit animation that finishes after a new show never orders the panel out.
    private var visibilityGeneration = 0
    private var hiding = false
    private let autoClose = IdleCountdown()
    private var running = false
    private var observationGeneration = UUID()
    private var selectedScreen: NSScreen?
    private var expanded = false
    private var contentHeight = NotchOverlayGeometry.compactHeight
    private var announcedPhase: DictationDisplayState.Phase?
    /// Top-left corner the user dragged the panel to. Kept in memory only and forgotten when the user
    /// closes the overlay, so reopening or relaunching starts at the default position below the notch.
    var userAnchor: CGPoint?
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
        synchronize()
    }

    func stop() {
        autoClose.stop()
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
            autoClose.stop()
            hide()
            announcedPhase = nil
            dragStart = nil
            forgetPlacementIfClosed()
            return
        }
        let resized = expanded != state.isExpanded
        expanded = state.isExpanded
        show(animateResize: resized)
        announce(state)
        // Every change on the overlay restarts the wait, so it only closes after the user has left it alone.
        if let limit = Self.autoCloseLimit(state, setting: model.overlayAutoCloseLimit) {
            autoClose.restart(after: limit) { [weak self] in self?.autoCloseExpired(after: limit) }
        } else {
            autoClose.stop()
        }
    }

    /// The overlay closes by itself only while no dictation runs and the setting is on.
    nonisolated static func autoCloseLimit(_ state: DictationDisplayState, setting: Duration?) -> Duration? {
        state.isDictating ? nil : setting
    }

    /// Never closes under the pointer: the user is about to click or still reading.
    private func autoCloseExpired(after limit: Duration) {
        if let panel, NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
            autoClose.restart(after: limit) { [weak self] in self?.autoCloseExpired(after: limit) }
            return
        }
        model.dismissOverlay()
    }

    /// The user's close button drops the dragged position; hiding for focused Settings keeps it.
    func forgetPlacementIfClosed() {
        if !model.overlayRequested { userAnchor = nil }
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

    /// Fades out, then leaves the screen. Showing again during the fade reverses it from where it is.
    private func hide() {
        guard let panel, panel.isVisible, !hiding else { return }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        // Hidden before its entrance began: nothing to fade, and a transparent panel must not stay on screen.
        guard presence.shown else {
            panel.orderOut(nil)
            return
        }
        hiding = true
        withAnimation(OverlayMotion.disappear) {
            presence.shown = false
        } completion: { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            self.hiding = false
            if !self.model.overlayVisible { panel.orderOut(nil) }
        }
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
                presence: presence,
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
            self.hosting = hosting
            panel = window
        }
        guard let panel else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let appear = reduceMotion ? OverlayMotion.reduced : OverlayMotion.appear
        place(panel, animated: animateResize && panel.isVisible && !reduceMotion)
        if panel.isVisible {
            // Shown again while fading out: turn around from the current state.
            guard hiding else { return }
            hiding = false
            visibilityGeneration += 1
            withAnimation(appear) { presence.shown = true }
            return
        }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        presence.shown = false
        hosting?.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        // The hidden state has to reach the screen once before the entrance can animate from it.
        Task { @MainActor [weak self] in
            guard let self, self.visibilityGeneration == generation, self.model.overlayVisible else { return }
            withAnimation(appear) { self.presence.shown = true }
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
                                  anchor: CGPoint(x: panel.frame.minX, y: panel.frame.maxY))
        dragStart = start
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? selectedScreen
        else { return }
        let wanted = CGPoint(x: start.anchor.x + mouse.x - start.mouse.x, y: start.anchor.y + mouse.y - start.mouse.y)
        let frame = NotchOverlayGeometry.frame(anchor: wanted, screen: screen.frame, expanded: expanded,
                                               contentHeight: contentHeight)
        userAnchor = CGPoint(x: frame.minX, y: frame.maxY)
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
                context.duration = OverlayMotion.duration
                context.timingFunction = OverlayMotion.resizeCurve
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

struct NotchOverlayView: View {
    let model: AppModel
    let presence: OverlayPresence
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
        VStack(alignment: .leading, spacing: Spacing.s) {
            header(state)
            if state.isExpanded { details(state) }
        }
        .animation(reduceMotion ? OverlayMotion.reduced : OverlayMotion.layout, value: state.layoutKey)
        .padding(.horizontal, NotchOverlayGeometry.sideInset)
        .padding(.top, NotchOverlayGeometry.verticalInset)
        .padding(.bottom, state.isExpanded ? Spacing.m : NotchOverlayGeometry.verticalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Content decides the height; the controller sizes the panel to this measurement.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(white: 0.11), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.7 : 0.12), lineWidth: 1))
        .clipShape(shape)
        // Entrance and exit: out of the notch, anchored at the top edge. Reduce Motion keeps the fade only.
        .scaleEffect(presence.shown || reduceMotion ? 1 : OverlayMotion.hiddenScale, anchor: .top)
        .offset(y: presence.shown || reduceMotion ? 0 : OverlayMotion.hiddenOffset)
        .opacity(presence.shown ? 1 : 0)
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
        HStack(spacing: Spacing.s) {
            indicator(state)
                .frame(width: NotchOverlayGeometry.indicatorSize, height: NotchOverlayGeometry.indicatorSize)
            HStack(spacing: Spacing.s) {
                Text(state.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    // Status words change within a phase too (connecting, then recording); cross-fade them.
                    .animation(reduceMotion ? OverlayMotion.reduced : OverlayMotion.layout, value: state.title)
                    .help(state.title)
                    .accessibilityIdentifier("notch-status")
                if let target = state.targetName {
                    Label(target, systemImage: "arrow.turn.down.right")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .layoutPriority(-1)
                        .transition(.opacity)
                        .accessibilityLabel(String(localized: "입력 중인 앱: \(target)"))
                        .accessibilityIdentifier("notch-target")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Buttons carry a 2 pt transparent margin around their visible circle, so circles sit 8 pt apart, and
            // the row reaches 4 pt into the side inset so the last circle is 10 pt from the edge, as from the top:
            // concentric with the capsule's rounded end.
            HStack(spacing: Spacing.xs) {
                ForEach(state.headerActions, id: \.self) { action in
                    OverlayIconButton(symbol: symbol(for: action), label: label(for: action, state),
                                      id: identifier(for: action), prominent: action == .start) {
                        perform(action)
                    }
                }
            }
            .padding(.trailing, -Spacing.xs)
        }
        .frame(minHeight: NotchOverlayGeometry.rowHeight)
    }

    @ViewBuilder
    private func indicator(_ state: DictationDisplayState) -> some View {
        Group {
            if state.isBusy {
                ProgressView().controlSize(.small).tint(.white)
            } else if state.phase == .recording {
                LevelMeter(level: { model.inputLevel })
            } else {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.phase == .error ? Color.orange : Color.white.opacity(0.82))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(state.title)
    }

    @ViewBuilder
    private func details(_ state: DictationDisplayState) -> some View {
        if !state.message.isEmpty {
            Text(state.message)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.orange)
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(state.message)
                .accessibilityIdentifier("notch-error")
        }
        if !state.recoveryActions.isEmpty {
            HStack(spacing: Spacing.s) {
                ForEach(state.recoveryActions, id: \.self) { action in
                    OverlayTextButton(title: action == .start ? String(localized: "다시 시도") + shortcutSuffix(.toggleDictation) : String(localized: "설정 확인"),
                                      symbol: action == .start ? "arrow.clockwise" : "gearshape",
                                      id: action == .start ? "notch-retry" : "notch-open-settings") {
                        perform(action)
                    }
                }
                // The overlay never becomes key, so its text can't be selected; copying is the way to keep the error.
                OverlayTextButton(title: String(localized: "오류 복사"), symbol: "doc.on.doc", id: "notch-copy-error") {
                    model.copyError()
                }
                Spacer(minLength: 0)
            }
        }
        if !state.transcript.isEmpty {
            TranscriptViewport(text: state.transcript, followsTail: state.followsTail, uncertain: state.uncertainWords)
                .transition(entering)
        }
        if !state.noteText.isEmpty {
            Text(state.noteText)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.68))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(state.noteText)
                .accessibilityIdentifier("notch-feedback")
        }
        if let kind = state.retainedKind {
            retainedLine(state.retained, kind: kind)
        } else if state.offersTranscriptActions, !state.inserted {
            transcriptActions
        }
        if !state.history.isEmpty {
            HistoryList(records: state.history, more: state.moreHistory, entering: entering) { model.copyHistory($0) }
        }
    }

    /// New content arrives from above and pushes older content down.
    private var entering: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }


    private var transcriptActions: some View {
        HStack(spacing: Spacing.s) {
            OverlayTextButton(title: String(localized: "복사"), symbol: "doc.on.doc", id: "notch-copy") { model.copyTranscript() }
            OverlayTextButton(title: String(localized: "붙여넣기") + shortcutSuffix(.pasteTranscript), symbol: "arrow.down.doc",
                              id: "notch-paste") {
                model.pasteTranscript()
            }
            Spacer(minLength: 0)
        }
    }

    /// Older or unconfirmed text: labelled, dimmed, one line, with compact copy and paste.
    private func retainedLine(_ text: String, kind: DictationDisplayState.RetainedKind) -> some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(kind == .previous ? String(localized: "이전 받아쓰기") : String(localized: "중단 전 받은 텍스트 · 확정 아님"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(text)
                    .font(.callout)
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
        .padding(.trailing, -Spacing.xxs)
    }

    private func perform(_ action: DictationDisplayState.Action) {
        switch action {
        case .start, .finish: model.toggleRecording()
        case .cancel: onCancel()
        case .settings: model.openSettings()
        case .dismiss: model.dismissOverlay()
        case .copy: model.copyTranscript()
        }
    }

    private func symbol(for action: DictationDisplayState.Action) -> String {
        switch action {
        case .start: "mic.fill"
        case .finish: "stop.fill"
        case .cancel, .dismiss: "xmark"
        case .settings: "gearshape"
        case .copy: "doc.on.doc"
        }
    }

    private func label(for action: DictationDisplayState.Action, _ state: DictationDisplayState) -> String {
        switch action {
        case .start: String(localized: "받아쓰기 시작") + shortcutHint(.toggleDictation)
        case .finish: String(localized: "녹음 마치기") + shortcutHint(.toggleDictation)
        case .cancel: state.phase == .recording ? String(localized: "녹음 취소") : String(localized: "받아쓰기 취소")
        case .settings: String(localized: "설정 열기")
        case .dismiss: String(localized: "닫기")
        case .copy: String(localized: "복사")
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
        case .copy: "notch-copy"
        }
    }
}

/// Recording indicator: bars that follow the microphone, so the user sees at a glance that their voice arrives.
/// Reduce Motion freezes it into a still red mark.
private struct LevelMeter: View {
    let level: @MainActor () -> Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let shape: [CGFloat] = [0.55, 1, 0.8, 0.45]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            // Square root spreads quiet speech over the bars; peaks above about 0.4 fill them.
            let loudness = reduceMotion ? 0.35 : min(1, CGFloat(level()).squareRoot() * 1.6)
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(Self.shape.indices, id: \.self) { index in
                    let wobble = reduceMotion ? 1 : 0.8 + 0.2 * sin(time * 9 + Double(index) * 1.7)
                    Capsule()
                        .fill(Color.red)
                        .frame(width: 3, height: 4 + 12 * loudness * Self.shape[index] * wobble)
                }
            }
            .animation(reduceMotion ? nil : OverlayMotion.meter, value: loudness)
        }
        .frame(width: NotchOverlayGeometry.indicatorSize, height: NotchOverlayGeometry.indicatorSize)
    }
}

/// Earlier dictations, pushed down by the new one: a labelled inset group, so they never read as the current text,
/// with each older row dimmer and one text style smaller. "More" opens the rest in a scrolling list.
private struct HistoryList: View {
    let records: [DictationRecord]
    let more: [DictationRecord]
    let entering: AnyTransition
    let copy: (DictationRecord) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `State` struct instead of the `@State` macro: the CLT toolchain ships no SwiftUIMacros plugin.
    private let showsAll = State(initialValue: false)
    private let listHeight = State(initialValue: CGFloat(0))
    static let expandedMaxHeight: CGFloat = 220

    var body: some View {
        let expanded = showsAll.wrappedValue && !more.isEmpty
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .center) {
                Text(String(localized: "받아쓰기 기록"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if !more.isEmpty {
                    Button {
                        // Animated like every other layout change, so the list opens with the panel instead of
                        // jumping while the panel frame is still growing.
                        withAnimation(reduceMotion ? OverlayMotion.reduced : OverlayMotion.layout) {
                            showsAll.wrappedValue.toggle()
                        }
                    } label: {
                        Label(expanded ? String(localized: "접기") : String(localized: "더보기 \(more.count)"),
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(OverlayControlStyle(shape: .capsule, prominent: false))
                    .accessibilityValue(expanded ? String(localized: "펼침") : String(localized: "접힘"))
                    .accessibilityIdentifier("notch-history-more")
                }
            }
            if expanded {
                ScrollView(.vertical) {
                    rows(records + more)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight.wrappedValue = $0 }
                }
                .contentMargins(.trailing, Spacing.m, for: .scrollContent)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(listHeight.wrappedValue, 1), Self.expandedMaxHeight))
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                rows(records)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        // The history group sits a step further from the current dictation than its parts sit from each other.
        .padding(.top, Spacing.xs)
        // A new dictation folds the list back to its three newest rows.
        .onChange(of: more.isEmpty) { _, empty in if empty { showsAll.wrappedValue = false } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "받아쓰기 기록"))
        .accessibilityIdentifier("notch-history")
    }

    private func rows(_ shown: [DictationRecord]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { depth, record in
                VStack(spacing: 0) {
                    if depth > 0 {
                        Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, Spacing.s)
                    }
                    HStack(alignment: .center, spacing: Spacing.s) {
                        Text(record.text)
                            .font(OverlayMotion.historyFont(depth: depth))
                            .foregroundStyle(.white.opacity(OverlayMotion.historyOpacity(depth: depth)))
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(record.text)
                            .accessibilityLabel(String(localized: "이전 받아쓰기") + ": " + record.text)
                            .accessibilityIdentifier("notch-history-row")
                        OverlayIconButton(symbol: "doc.on.doc", label: String(localized: "이 받아쓰기 복사"),
                                          id: "notch-history-copy", prominent: false) {
                            copy(record)
                        }
                    }
                    // The copy circle sits 4 pt from the group's edges (2 pt padding + its 2 pt hit margin).
                    .padding(.leading, Spacing.s)
                    .padding(.trailing, Spacing.xxs)
                    .padding(.vertical, Spacing.xxs)
                }
                .transition(entering)
            }
        }
    }
}

/// Scrolls only when the measured text exceeds the viewport, so short text leaves no gutter.
private struct TranscriptViewport: View {
    let text: String
    let followsTail: Bool
    var uncertain: [String] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `State` struct instead of the `@State` macro: the CLT toolchain ships no SwiftUIMacros plugin.
    private let textHeight = State(initialValue: CGFloat(19))
    private let maxHeight = State(initialValue: NotchOverlayGeometry.fallbackMaxTranscriptHeight)
    /// Underlines, with dots, each word Soniox was unsure of, found in reading order.
    static func marked(_ text: String, uncertain: [String]) -> AttributedString {
        var result = AttributedString(text)
        var searchFrom = result.startIndex
        for word in uncertain {
            guard let range = result[searchFrom...].range(of: word) else { continue }
            result[range].underlineStyle = Text.LineStyle(pattern: .dot, color: .orange)
            result[range].foregroundColor = .white.opacity(0.75)
            searchFrom = range.upperBound
        }
        return result
    }

    private static let lineSample = Array(repeating: "Ag", count: NotchOverlayGeometry.maxTranscriptLines)
        .joined(separator: "\n")

    private func styled(_ text: Text) -> some View {
        text.font(.title3.weight(.medium)).lineSpacing(2)
    }

    var body: some View {
        ScrollView(.vertical) {
            styled(Text(Self.marked(text, uncertain: uncertain)))
                .foregroundStyle(.white)
                .contentTransition(reduceMotion ? .identity : .interpolate)
                .animation(reduceMotion ? nil : OverlayMotion.liveText, value: text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight.wrappedValue = $0 }
                .accessibilityIdentifier("notch-transcript")
        }
        // The overlay scroller draws over content; a trailing gutter keeps it off the text.
        .contentMargins(.trailing, Spacing.m, for: .scrollContent)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .defaultScrollAnchor(followsTail ? .bottom : .top)
        .defaultScrollAnchor(followsTail ? .bottom : .top, for: .sizeChanges)
        .frame(height: NotchOverlayGeometry.transcriptViewportHeight(textHeight: textHeight.wrappedValue,
                                                                     maxHeight: maxHeight.wrappedValue))
        // Five invisible lines in the same style measure the scroll cap at the current text size.
        .background(alignment: .top) {
            styled(Text(Self.lineSample))
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { maxHeight.wrappedValue = $0 }
        }
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
                .font(.callout.weight(.medium))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(OverlayControlStyle(shape: .capsule, prominent: false))
        .help(title)
        .accessibilityIdentifier(id)
    }
}

struct OverlayControlStyle: ButtonStyle {
    enum Shape { case circle, capsule }
    let shape: Shape
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed || prominent ? 1 : 0.78))
        let pressed = configuration.isPressed
        let base = prominent ? 0.18 : 0.08
        let fill = Color.white.opacity(configuration.isPressed ? 0.26 : base)
        return Group {
            switch shape {
            case .circle:
                // A 24 pt circle inside a transparent 28 pt hit area.
                label.frame(width: 24, height: 24)
                    .background(fill, in: Circle())
                    .frame(width: NotchOverlayGeometry.minimumHitSize, height: NotchOverlayGeometry.minimumHitSize)
                    .contentShape(Rectangle())
            case .capsule:
                // As tall as the 24 pt circles, with the 28 pt hit area around it.
                label.padding(.horizontal, Spacing.m).frame(minHeight: 24)
                    .background(fill, in: Capsule())
                    .frame(minHeight: NotchOverlayGeometry.minimumHitSize)
                    .contentShape(Rectangle())
            }
        }
        // The press is answered at once by the control itself; a scale this small needs no Reduce Motion variant.
        .scaleEffect(pressed ? OverlayMotion.pressedScale : 1)
        .animation(OverlayMotion.press, value: pressed)
    }
}
