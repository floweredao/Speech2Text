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
    /// Every earlier dictation, newest first, in the one "Dictation History" group: collapsed it shows only the
    /// newest, and its expand button shows the rest. The previous result is the group's newest row, not a line of its
    /// own; only the finished result shown as the body stays out of it.
    let history: [DictationRecord]
    /// The newest history row is the previous result `model.transcript` still holds, so it offers paste as well.
    let historyPastesNewest: Bool
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
        // The newest record is the finished result itself until a new dictation starts; the previous result joins the
        // history group instead of a separate "previous" line.
        switch phase {
        case .idle: self.history = []
        case .result: self.history = Array(history.dropFirst())
        default: self.history = history
        }
        historyPastesNewest = retainedKind == .previous && !self.history.isEmpty
    }

    /// The previous result has no history row (it was only a spoken command), so it keeps its own labelled line;
    /// unconfirmed text heard before an error is never history.
    var showsRetainedLine: Bool { retainedKind == .unfinished || (retainedKind == .previous && !historyPastesNewest) }

    /// Rows the history group shows: none until the user expands it.
    func historyRows(expanded: Bool) -> [DictationRecord] {
        expanded ? history : Array(history.prefix(NotchOverlayGeometry.collapsedHistoryRows))
    }
    var historyCanExpand: Bool { history.count > NotchOverlayGeometry.collapsedHistoryRows }

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

    /// When recording ends, Settings takes the slot Finish had; a second click on Finish must not open it.
    /// A header button ignores clicks until it has been on screen this long.
    static let pressGuard: Duration = .milliseconds(800)
    nonisolated static func acceptsPress(shownFor: Duration) -> Bool { shownFor >= pressGuard }

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
    /// History rows shown until the user expands the group (owner request 2026-10-25: none, only the label and the
    /// expand button, replacing the 2026-10-23 one-row decision).
    static let collapsedHistoryRows = 0
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
    /// One curve and duration for every layout change, animated by SwiftUI alone; the panel window waits this long
    /// before it gives up height. A strong ease-out, quick while the user watches and soft as it settles.
    static let duration = 0.24
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
    /// Each placement replaces any resize still waiting for the content's animation to end.
    private var resizeGeneration = 0
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

    /// The display a demo recording puts the overlay on instead of the one under the pointer (`--demo-screen`).
    static var demoScreenID: CGDirectDisplayID?

    /// Shows the overlay on the display under the pointer. Never activates the app.
    func present() {
        guard running else { return }
        selectedScreen = Self.demoScreenID.flatMap { id in
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
        } ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
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
        resizeGeneration += 1
        guard panel.frame != frame else { return }
        // SwiftUI alone animates the visible height; the clear window only has to hold it. Animating the window frame
        // as well made a second, unsynchronized owner: AppKit applied the new height a frame before the new origin, so
        // the whole panel jumped up and back as the history opened (recorded 2026-10-25). The window takes a taller
        // frame at once and gives up a shorter one only after the content has finished shrinking into it.
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
        let generation = resizeGeneration
        let shrinking = frame.height < panel.frame.height
        if !shrinking { panel.setFrame(frame, display: true) }
        // A clear window's shadow is drawn from its content once; redraw it while the content changes shape.
        let start = ContinuousClock.now
        Task { @MainActor [weak self, weak panel] in
            while let self, let panel, self.resizeGeneration == generation {
                panel.invalidateShadow()
                guard ContinuousClock.now - start < .seconds(OverlayMotion.duration) else {
                    if shrinking { panel.setFrame(frame, display: true) }
                    panel.invalidateShadow()
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
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
            // The destination finishes the status sentence, so it stands a wider gap from the title than its icon
            // stands from its own words: nearer means more closely related.
            HStack(spacing: Spacing.m) {
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
                    OverlayTargetChip(name: target, icon: model.liveTargetIcon, typed: state.inserted)
                        .layoutPriority(-1)
                        .transition(.opacity)
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
        if state.showsRetainedLine, let kind = state.retainedKind {
            retainedLine(state.retained, kind: kind)
        } else if state.phase == .result, !state.inserted {
            transcriptActions
        }
        if !state.history.isEmpty {
            HistoryList(state: state, entering: entering,
                        paste: { model.pasteTranscript() },
                        pasteLabel: String(localized: "붙여넣기") + shortcutHint(.pasteTranscript)) { model.copyHistory($0) }
        }
    }

    /// New content arrives from above and pushes older content down.
    private var entering: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }


    private var transcriptActions: some View {
        // Small round buttons, the same as the history rows' copy button (owner request 2026-10-25), so every copy
        // and paste in the overlay is one control; the circle edge lines up with the text above.
        HStack(spacing: Spacing.xs) {
            OverlayIconButton(symbol: "doc.on.doc", label: String(localized: "복사"), id: "notch-copy", prominent: false) {
                model.copyTranscript()
            }
            OverlayIconButton(symbol: "arrow.down.doc", label: String(localized: "붙여넣기") + shortcutHint(.pasteTranscript),
                              id: "notch-paste", prominent: false) {
                model.pasteTranscript()
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, -Spacing.xxs)
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

/// Every earlier dictation in one labelled inset group, so none reads as the current text. Collapsed it shows only its
/// label (owner request 2026-10-25); the round expand button (owner request 2026-10-23, 2026-10-24, 2026-10-25) shows the rest. Every row has the
/// same text style and color and grows to fit its whole text (owner request 2026-10-25: no dimmer, smaller rows, no
/// lines squeezed into one row). A new dictation folds it back.
///
/// Expanding animates one thing, the clip height, between two measured heights; the rows are always laid out, so nothing
/// is inserted or re-measured mid-animation, and the extra rows only fade (beui.dev Collapsible, StyleGallery
/// motion/interaction-recipes Disclosure).
struct HistoryList: View {
    let state: DictationDisplayState
    let entering: AnyTransition
    let paste: () -> Void
    let pasteLabel: String
    let copy: (DictationRecord) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `State` struct instead of the `@State` macro: the CLT toolchain ships no SwiftUIMacros plugin.
    private let showsAll: State<Bool>
    private let listHeight = State(initialValue: CGFloat(0))
    static let expandedMaxHeight: CGFloat = 220

    init(state: DictationDisplayState, entering: AnyTransition, expanded: Bool = false, paste: @escaping () -> Void,
         pasteLabel: String, copy: @escaping (DictationRecord) -> Void) {
        self.state = state
        self.entering = entering
        self.paste = paste
        self.pasteLabel = pasteLabel
        self.copy = copy
        showsAll = State(initialValue: expanded)
    }

    var body: some View {
        let expanded = showsAll.wrappedValue && state.historyCanExpand
        let motion = reduceMotion ? OverlayMotion.reduced : OverlayMotion.layout
        let shownHeight = expanded ? listHeight.wrappedValue : 0
        let height = min(shownHeight, Self.expandedMaxHeight)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(String(localized: "받아쓰기 기록"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if state.historyCanExpand {
                    Button {
                        // On the panel's own curve, so the list opens with the panel instead of being cut while the
                        // panel frame is still growing.
                        withAnimation(motion) { showsAll.wrappedValue.toggle() }
                    } label: {
                        // One chevron that turns over, so the button reads as the same control in both states;
                        // Reduce Motion swaps the symbol instead of turning it.
                        Group {
                            if reduceMotion {
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            } else {
                                Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? -180 : 0))
                            }
                        }
                        .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(OverlayControlStyle(shape: .circle, prominent: false))
                    .help(expanded ? String(localized: "접기") : String(localized: "받아쓰기 기록 \(state.history.count)개 모두 보기"))
                    .accessibilityLabel(expanded ? String(localized: "접기") : String(localized: "펼치기"))
                    .accessibilityValue(expanded ? String(localized: "펼침") : String(localized: "접힘"))
                    .accessibilityIdentifier("notch-history-toggle")
                }
            }
            // The round button lines up with the rows' copy buttons below it: same inset from the group's edge.
            .padding(.trailing, Self.trailingInset)
            .frame(minHeight: NotchOverlayGeometry.minimumHitSize)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    rows(state.history, expanded: expanded)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight.wrappedValue = $0 }
                }
                // No scroller: a legacy scroller would take a column of its own and push the copy buttons off the
                // header buttons' column. Instead the edge that has more behind it fades out (owner report
                // 2026-10-25: with no scroller nothing showed there was more below).
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDisabled(shownHeight <= Self.expandedMaxHeight)
                // Folded, the rows below the newest are hidden, so there is nothing more to show.
                .scrollEdgeFade(enabled: expanded && shownHeight > Self.expandedMaxHeight)
                .frame(height: height, alignment: .top)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // The group reaches out of the content column so its text starts on the transcript's edge and its
                // copy circles end on the header buttons' column, each 6 pt inside the group (owner request
                // 2026-10-25: one column for every round button).
                .padding(.leading, -Self.groupInset)
                .padding(.trailing, -(Self.groupInset + Spacing.xxs))
                // Folded, the group takes no room at all: only the label and its expand button show.
                .opacity(expanded ? 1 : 0)
                .padding(.top, expanded ? Spacing.xs : 0)
                .accessibilityHidden(!expanded)
                .allowsHitTesting(expanded)
                .onChange(of: expanded) { _, open in
                    if !open, let first = state.history.first { withAnimation(motion) { proxy.scrollTo(first.id, anchor: .top) } }
                }
            }
        }
        // The history group sits a step further from the current dictation than its parts sit from each other.
        .padding(.top, Spacing.xs)
        // A new dictation folds the group back to its newest row.
        .onChange(of: state.isDictating) { _, dictating in
            if dictating { withAnimation(motion) { showsAll.wrappedValue = false } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "받아쓰기 기록"))
        .accessibilityIdentifier("notch-history")
    }

    private func rows(_ records: [DictationRecord], expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.id) { depth, record in
                let hidden = !expanded
                VStack(spacing: 0) {
                    if depth > 0 {
                        // Across the whole row, from the text's edge to the copy circle's edge.
                        Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.horizontal, Self.groupInset)
                    }
                    // Buttons sit at the top so they stay beside the first line however tall the row grows.
                    HStack(alignment: .top, spacing: Spacing.s) {
                        Text(record.text)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Centers a one-line row on its 28 pt buttons and gives longer rows the same margin
                            // above the first line as below the last.
                            .padding(.vertical, Self.textInset)
                            .accessibilityLabel(String(localized: "이전 받아쓰기") + ": " + record.text)
                            .accessibilityIdentifier("notch-history-row")
                        OverlayIconButton(symbol: "doc.on.doc", label: String(localized: "이 받아쓰기 복사"),
                                          id: "notch-history-copy", prominent: false) {
                            copy(record)
                        }
                        if depth == 0 && state.historyPastesNewest {
                            OverlayIconButton(symbol: "arrow.down.doc", label: pasteLabel, id: "notch-paste",
                                              prominent: false, action: paste)
                        }
                    }
                    // 6 pt from the group's left edge to the text and from the copy circle to its right edge.
                    .padding(.leading, Self.groupInset)
                    .padding(.trailing, Self.groupInset - Spacing.xxs)
                    .padding(.vertical, Spacing.xxs)
                }
                .id(record.id)
                .opacity(hidden ? 0 : 1)
                .accessibilityHidden(hidden)
                .allowsHitTesting(!hidden)
                .transition(entering)
            }
        }
    }

    /// (28 pt button - one callout line) / 2, so a single line sits on the buttons' center line.
    static let textInset: CGFloat = 6
    /// The header buttons reach 4 pt into the panel's side inset; the expand button does the same, so all the circles
    /// end 10 pt from the panel edge.
    static let trailingInset: CGFloat = -Spacing.xs
    /// Inner margin of the history group: 12 pt panel inset - 6 = 6 pt outer margin on the left, 4 on the right.
    static let groupInset: CGFloat = 6
}

/// Fades the top or bottom edge of a scroll view while there is more content past it, so a list with no scroller still
/// shows that it continues (HIG Scroll views: show that more content exists; StyleGallery scroll-shadow pattern).
private struct ScrollEdgeFade: ViewModifier {
    var enabled = true
    private let edges = State(initialValue: (top: false, bottom: false))
    static let length: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: [Bool].self) { geo in
                // Measured on the visible part of the content, so content insets and rounding never read as more.
                [geo.visibleRect.minY > 1, geo.visibleRect.maxY < geo.contentSize.height - 1]
            } action: { _, now in
                withAnimation(.easeOut(duration: 0.15)) { edges.wrappedValue = (now[0], now[1]) }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(enabled && edges.wrappedValue.top ? 0 : 1), .black],
                                   startPoint: .top, endPoint: .bottom).frame(height: Self.length)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(enabled && edges.wrappedValue.bottom ? 0 : 1)],
                                   startPoint: .top, endPoint: .bottom).frame(height: Self.length)
                }
            }
    }
}

extension View {
    func scrollEdgeFade(enabled: Bool = true) -> some View { modifier(ScrollEdgeFade(enabled: enabled)) }
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
        // No scroller (owner report 2026-10-25): with a mouse attached the legacy scroller took a column of its own
        // beside the header buttons and the text stopped short of them. The text now runs to the same edge as the
        // header buttons; a line cut at the bottom edge shows there is more, and the view follows the newest words.
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.never)
        .scrollEdgeFade()
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

/// Where the dictated text goes: the app's own icon and a short sentence naming it ("Typing in Discord"), so the
/// destination reads without a symbol to decode.
///
/// It is a label, not a control, so it wears no capsule: in this overlay a filled capsule or circle means "press me"
/// (HIG Buttons, Layout: differentiate controls from content). It continues the title's sentence at the title's size,
/// one step down in hierarchy through weight and the secondary label color (HIG Labels, Typography), and the icon is
/// sized to the 16 pt body line like a Finder row.
struct OverlayTargetChip: View {
    let name: String
    let icon: NSImage?
    /// The text is already in the field, so the sentence moves to the past tense.
    let typed: Bool

    static let iconSize: CGFloat = 16

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .accessibilityHidden(true)
            }
            Text(typed ? String(localized: "\(name)에 입력됨") : String(localized: "\(name)에 입력 중"))
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(String(localized: "입력 중인 앱: \(name)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "입력 중인 앱: \(name)"))
        .accessibilityIdentifier("notch-target")
    }
}

private struct OverlayIconButton: View {
    let symbol: String
    let label: String
    let id: String
    let prominent: Bool
    let action: () -> Void
    /// Kept per action, so a button that replaces another in the same slot starts its own wait.
    private let appearedState = State(initialValue: ContinuousClock.now)

    var body: some View {
        Button {
            if DictationDisplayState.acceptsPress(shownFor: ContinuousClock.now - appearedState.wrappedValue) { action() }
        } label: {
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
