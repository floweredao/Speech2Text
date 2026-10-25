import AppKit
import CoreGraphics
import DictationSpeech
import SwiftUI
import Testing
@testable import Speech2Text

// MARK: Geometry

/// 14" MacBook Pro-like notched display: 1512x982 points, 32 pt safe top, menu bar inside it.
private let notchScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let notchVisible = CGRect(x: 0, y: 0, width: 1512, height: 950)

@Suite struct NotchOverlayGeometryTests {
    @Test func compactCapsuleSitsBelowNotchAndIgnoresStaleContentHeight() {
        let frame = NotchOverlayGeometry.frame(screen: notchScreen, visible: notchVisible, safeTop: 32,
                                               expanded: false, contentHeight: 196)
        #expect(frame.height == NotchOverlayGeometry.compactHeight)
        #expect(frame.width == NotchOverlayGeometry.compactWidth)
        #expect(frame.maxY == notchScreen.maxY - 32 - NotchOverlayGeometry.topGap)
        #expect(frame.midX == notchScreen.midX)
    }

    /// Regression: a fixed 196 pt expanded height left a blank block above a one-sentence result.
    @Test func shortResultUsesMeasuredHeightNotFixedBlock() {
        let frame = NotchOverlayGeometry.frame(screen: notchScreen, visible: notchVisible, safeTop: 32,
                                               expanded: true, contentHeight: 98)
        #expect(frame.height == 98)
        #expect(frame.height < 196)
    }

    @Test(arguments: [0, 20, 44, 98, 180, 260] as [CGFloat])
    func topEdgeStaysAnchoredWhileHeightChanges(contentHeight: CGFloat) {
        let compact = NotchOverlayGeometry.frame(screen: notchScreen, visible: notchVisible, safeTop: 32,
                                                 expanded: false, contentHeight: 0)
        let expanded = NotchOverlayGeometry.frame(screen: notchScreen, visible: notchVisible, safeTop: 32,
                                                  expanded: true, contentHeight: contentHeight)
        #expect(expanded.maxY == compact.maxY)
        #expect(expanded.height >= NotchOverlayGeometry.compactHeight)
    }

    @Test func tallContentIsClampedToAvailableScreenHeight() {
        let short = CGRect(x: 0, y: 0, width: 800, height: 200)
        let visible = CGRect(x: 0, y: 0, width: 800, height: 176)
        let frame = NotchOverlayGeometry.frame(screen: short, visible: visible, safeTop: 0,
                                               expanded: true, contentHeight: 600)
        #expect(frame.height == 200 - 24 - NotchOverlayGeometry.topGap - NotchOverlayGeometry.margin)
        #expect(frame.minY >= short.minY)
    }

    @Test func topInsetUsesLargestOfSafeAreaAuxiliaryAndMenuBar() {
        let menuBarOnly = NotchOverlayGeometry.frame(screen: notchScreen, visible: notchVisible, safeTop: 0,
                                                     expanded: false, contentHeight: 0)
        #expect(menuBarOnly.maxY == 950 - NotchOverlayGeometry.topGap)
        let auxiliary = NotchOverlayGeometry.frame(screen: notchScreen, visible: notchVisible, safeTop: 0,
                                                   auxiliaryTop: 38, expanded: false, contentHeight: 0)
        #expect(auxiliary.maxY == 982 - 38 - NotchOverlayGeometry.topGap)
    }

    @Test func widthIsCompactWhenIdleAndBoundedWhenExpanded() {
        #expect(NotchOverlayGeometry.width(screenWidth: 1512, expanded: false) == 340)
        #expect(abs(NotchOverlayGeometry.width(screenWidth: 1512, expanded: true) - 1512 * 0.3) < 0.001)
        #expect(NotchOverlayGeometry.width(screenWidth: 3000, expanded: true) == 520)
        #expect(NotchOverlayGeometry.width(screenWidth: 1000, expanded: true) == 420)
        #expect(NotchOverlayGeometry.width(screenWidth: 300, expanded: true) == 276)
        #expect(NotchOverlayGeometry.width(screenWidth: 10, expanded: false) == 0)
    }

    @Test func transcriptViewportFitsShortTextAndCapsLongText() {
        #expect(NotchOverlayGeometry.transcriptViewportHeight(textHeight: 19, maxHeight: 110) == 19)
        #expect(NotchOverlayGeometry.transcriptViewportHeight(textHeight: 400, maxHeight: 110) == 110)
        #expect(NotchOverlayGeometry.transcriptViewportHeight(textHeight: -5, maxHeight: 110) == 0)
    }

    /// Regression: reopening a moved result panel as a narrower recording capsule re-centered it, so the
    /// panel the user placed came back 90 pt to the side.
    @Test func draggedPanelKeepsItsTopLeftCornerWhenWidthOrHeightChanges() {
        let anchor = CGPoint(x: 400, y: 600)
        let compact = NotchOverlayGeometry.frame(anchor: anchor, screen: notchScreen, expanded: false,
                                                 contentHeight: 0)
        let expanded = NotchOverlayGeometry.frame(anchor: anchor, screen: notchScreen, expanded: true,
                                                  contentHeight: 180)
        #expect(compact.width != expanded.width)
        for frame in [compact, expanded] {
            #expect(frame.minX == anchor.x)
            #expect(frame.maxY == anchor.y)
        }
        #expect(expanded.height == 180)
    }

    @Test func draggedPanelStaysOnScreenNearEdges() {
        let corner = NotchOverlayGeometry.frame(anchor: CGPoint(x: -10, y: 20), screen: notchScreen,
                                                expanded: true, contentHeight: 180)
        #expect(corner.minX == notchScreen.minX)
        #expect(corner.minY == notchScreen.minY)
        #expect(corner.height == 180)
        let above = NotchOverlayGeometry.frame(anchor: CGPoint(x: 1510, y: 2000), screen: notchScreen,
                                               expanded: false, contentHeight: 0)
        #expect(above.maxX == notchScreen.maxX)
        #expect(above.maxY == notchScreen.maxY)
    }
}

// MARK: Display state

private let previous = "안녕하세요, 오늘은 맥에서 음성으로 글을 쓰고 있습니다."
private let live = "새로 말한 문장"

private func session(_ outcome: SpeechOutcome = .none, current: Bool = false) -> DictationSession {
    DictationSession(outcome: outcome, hasCurrentTranscript: current)
}

private func display(_ phase: SpeechPhase, error: Bool = false, transcript: String, feedback: String = "",
                     session: DictationSession) -> DictationDisplayState {
    DictationDisplayState(speechPhase: phase, hasError: error, status: "엔진 상태", transcript: transcript,
                          feedback: feedback, session: session)
}

@Suite struct DictationDisplayStateTests {
    @Test func launchIdleIsCompactAndCanStartRecording() {
        let state = display(.idle, transcript: "", session: session())
        #expect(state.phase == .idle)
        #expect(!state.isExpanded)
        #expect(state.headerActions == [.start, .settings, .dismiss])
    }

    @Test func connectingHidesPreviousTranscript() {
        let state = display(.preparing, transcript: previous, session: session())
        #expect(state.phase == .connecting)
        #expect(state.transcript.isEmpty)
        #expect(state.retained.isEmpty)
        #expect(!state.isExpanded)
        #expect(state.headerActions == [.cancel])
    }

    @Test func recordingBeforeFirstWordStaysCompact() {
        let state = display(.recording, transcript: previous, session: session())
        #expect(state.transcript.isEmpty)
        #expect(!state.isExpanded)
        #expect(state.headerActions == [.finish, .cancel])
    }

    @Test func recordingShowsLiveTextAndFollowsTail() {
        let state = display(.recording, transcript: live, session: session(current: true))
        #expect(state.transcript == live)
        #expect(state.followsTail)
        #expect(!state.offersTranscriptActions)
    }

    @Test func finishedResultOffersCopyPasteAndSettings() {
        let state = display(.idle, transcript: live, feedback: "입력했어요", session: session(.completed, current: true))
        #expect(state.phase == .result)
        #expect(state.transcript == live)
        #expect(!state.followsTail)
        #expect(state.retainedKind == nil)
        #expect(state.offersTranscriptActions)
        #expect(state.headerActions.contains(.start))
    }

    /// Regression: repeating the previous sentence was shown as "no new speech".
    @Test func repeatingTheSameSentenceIsStillANewResult() {
        let state = display(.idle, transcript: previous, session: session(.completed, current: true))
        #expect(state.phase == .result)
        #expect(state.transcript == previous)
        #expect(state.retained.isEmpty)
    }

    @Test func noSpeechResultLabelsRestoredTextAsPrevious() {
        let state = display(.idle, transcript: previous, feedback: "인식 없음", session: session(.empty))
        #expect(state.phase == .notice)
        #expect(state.transcript.isEmpty)
        #expect(state.retained == previous)
        #expect(state.retainedKind == .previous)
    }

    @Test func errorAfterFailedStartShowsMessageNotPreviousTranscript() {
        let state = display(.idle, error: true, transcript: previous, session: session(.failed))
        #expect(state.phase == .error)
        #expect(state.message == "엔진 상태")
        #expect(state.transcript.isEmpty)
        #expect(state.retained == previous)
        #expect(state.retainedKind == .previous)
        #expect(state.recoveryActions == [.start, .settings])
    }

    @Test func configurationErrorOffersSettingsInsteadOfRetry() {
        let state = DictationDisplayState(speechPhase: .idle, hasError: true, needsSettings: true, status: "키 없음",
                                          transcript: "", feedback: "", session: session(.failed))
        #expect(state.recoveryActions == [.settings])
    }

    @Test func errorMidRecordingMarksPartialTextUnfinished() {
        let state = display(.idle, error: true, transcript: live, session: session(.failed, current: true))
        #expect(state.retained == live)
        #expect(state.retainedKind == .unfinished)
        #expect(state.transcript.isEmpty)
    }

    /// Owner request: the overlay stays calm. Routine confirmations are not shown, and a result already typed into the
    /// field offers copy as one header button instead of a row of buttons; problems still show.
    @Test func routineConfirmationsStayOutOfTheWay() {
        let typed = DictationDisplayState(speechPhase: .idle, hasError: false, status: "마쳤어요", transcript: live,
                                          feedback: "입력했어요", session: session(.completed, current: true),
                                          feedbackIsRoutine: true, targetName: "Discord")
        #expect(typed.noteText.isEmpty)
        #expect(typed.inserted)
        #expect(typed.headerActions == [.copy, .start, .settings, .dismiss])
        #expect(typed.targetName == "Discord")
        let kept = display(.idle, transcript: live, feedback: "붙여넣어 주세요", session: session(.completed, current: true))
        #expect(kept.noteText == "붙여넣어 주세요")
        #expect(!kept.inserted)
        #expect(!kept.headerActions.contains(.copy))
        let listening = DictationDisplayState(speechPhase: .recording, hasError: false, status: "듣고 있어요", transcript: live,
                                              feedback: "실시간으로 입력해요", session: session(current: true),
                                              feedbackIsRoutine: true, targetName: "Notes")
        #expect(listening.noteText.isEmpty)
        #expect(listening.targetName == "Notes")
    }

    /// Owner request (2026-10-25): no dictation history. The previous result keeps its own labelled line with copy and
    /// paste; unconfirmed text heard before an error keeps its own label.
    @Test func previousResultKeepsItsOwnLine() {
        for state in [display(.idle, transcript: previous, feedback: "인식 없음", session: session(.empty)),
                      display(.idle, transcript: previous, feedback: "취소했어요", session: session(.cancelled)),
                      display(.idle, error: true, transcript: previous, session: session(.failed))] {
            #expect(state.retainedKind == .previous)
            #expect(state.showsRetainedLine)
        }
        let unfinished = display(.idle, error: true, transcript: live, session: session(.failed, current: true))
        #expect(unfinished.retainedKind == .unfinished)
        #expect(unfinished.showsRetainedLine)
        let idle = display(.idle, transcript: "", session: session())
        #expect(!idle.isExpanded)
    }

    /// Owner request: the overlay closes by itself only while no dictation runs, and never when the setting is off.
    @Test func overlayAutoClosesOnlyWhenNotDictating() {
        let limit = Duration.seconds(30)
        for phase in [SpeechPhase.preparing, .recording, .finishing] {
            #expect(NotchOverlayController.autoCloseLimit(display(phase, transcript: live, session: session(current: true)),
                                                          setting: limit) == nil)
        }
        let result = display(.idle, transcript: live, session: session(.completed, current: true))
        #expect(NotchOverlayController.autoCloseLimit(result, setting: limit) == limit)
        #expect(NotchOverlayController.autoCloseLimit(display(.idle, transcript: "", session: session()), setting: limit) == limit)
        #expect(NotchOverlayController.autoCloseLimit(result, setting: nil) == nil)
    }

    /// Regression: Settings opened by itself after a dictation. Its button appears where Finish was, so a second
    /// or late click on Finish landed on it; a header button that just appeared ignores that click.
    @Test func clickOnFinishThatLandsOnTheNewSettingsButtonIsIgnored() {
        let recording = display(.recording, transcript: live, session: session(current: true)).headerActions
        let result = display(.idle, transcript: live, session: session(.completed, current: true)).headerActions
        let slotFromRight = { (actions: [DictationDisplayState.Action], action: DictationDisplayState.Action) in
            actions.firstIndex(of: action).map { actions.count - 1 - $0 }
        }
        #expect(slotFromRight(recording, .finish) == slotFromRight(result, .settings))
        #expect(!DictationDisplayState.acceptsPress(shownFor: .milliseconds(300)))
        #expect(DictationDisplayState.acceptsPress(shownFor: .seconds(1)))
    }

    /// Regression: cancelling during finalization was shown as a finished result.
    @Test func cancelledRunShowsOnlyThePreviousResult() {
        let state = display(.idle, transcript: previous, feedback: "취소했어요", session: session(.cancelled))
        #expect(state.phase == .cancelled)
        #expect(state.transcript.isEmpty)
        #expect(state.retained == previous)
        #expect(state.retainedKind == .previous)
        #expect(state.headerActions == [.start, .settings, .dismiss])
    }
}

// MARK: Settings

@Suite struct SettingsModelTests {
    @MainActor @Test func openingSettingsSuppressesOverlayBeforePresentingWindow() {
        let model = AppModel()
        var visibleWhenPresented: Bool?
        model.settingsAction = { visibleWhenPresented = model.overlayVisible }
        model.openSettings()
        #expect(visibleWhenPresented == false)
        #expect(!model.overlayVisible)
        model.settingsAction = nil
    }

    /// Regression: Show in Settings did nothing, because Settings always has focus while its button is pressed.
    @MainActor @Test func showFromFocusedSettingsShowsTheOverlayUntilSettingsIsFocusedAgain() {
        let model = AppModel()
        model.openSettings()
        model.dismissOverlay()
        model.showOverlay()
        #expect(model.overlayVisible)
        model.appActivationChanged(isActive: true, settingsIsKey: true)
        #expect(!model.overlayVisible)
        model.appActivationChanged(isActive: false, settingsIsKey: true)
        #expect(model.overlayVisible)
    }

    /// Regression: Settings left open behind another app hid the overlay through whole dictations, because a window
    /// stays key while its app is inactive and no resign-key notice arrives.
    @MainActor @Test func settingsLeftOpenBehindAnotherAppDoesNotHideTheOverlay() {
        let model = AppModel()
        model.openSettings()
        model.appActivationChanged(isActive: false, settingsIsKey: true)
        #expect(model.overlayVisible)
        model.appActivationChanged(isActive: true, settingsIsKey: true)
        #expect(!model.overlayVisible)
    }

    /// Regression: closing a dragged overlay with its X and showing it again brought it back at the dragged spot.
    @MainActor @Test func closingTheOverlayForgetsTheDraggedPositionButSettingsFocusKeepsIt() {
        let model = AppModel()
        let overlay = NotchOverlayController(model: model)
        overlay.userAnchor = CGPoint(x: 400, y: 600)
        model.openSettings()
        overlay.forgetPlacementIfClosed()
        #expect(overlay.userAnchor == CGPoint(x: 400, y: 600))
        model.settingsFocused = false
        model.dismissOverlay()
        overlay.forgetPlacementIfClosed()
        #expect(overlay.userAnchor == nil)
    }

    @MainActor @Test func settingsRoundTripDoesNotReopenADismissedOverlay() {
        let model = AppModel()
        model.dismissOverlay()
        model.openSettings()
        model.settingsFocused = false
        #expect(!model.overlayVisible)
    }

    /// Regression: Jev's late answer typed the held-back last words into the field, but the overlay kept showing the
    /// text without them, because the answer changed nothing the overlay observes.
    @MainActor @Test func jevsAnswerRedrawsTheOverlayWithTheHeldBackWords() async throws {
        let model = AppModel()
        model.commandJudgeOverride = .jev
        model.jevKeyOverride = "test-key"
        model.jevJudge.send = { _ in throw URLError(.notConnectedToInternet) }
        model.speech.setDemoState(phase: .idle, transcript: "회의는 세 시예요. 다 지워", status: "", outcome: .completed)
        let (redrawn, signal) = AsyncStream<Void>.makeStream()
        let shown = withObservationTracking { model.transcript } onChange: { signal.yield() }
        #expect(shown == "회의는 세 시예요.")
        let observed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in redrawn { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            signal.finish()
            return first
        }
        #expect(observed)
        #expect(model.transcript == "회의는 세 시예요. 다 지워")
        model.commandJudgeOverride = nil
    }

    /// `--demo` drives the overlay with scripted text: no microphone, network, or other app's field is involved.
    @MainActor @Test func syntheticDemoStreamsStepsIntoResultWithoutNetwork() async throws {
        let model = AppModel()
        model.autoInsert = false
        let demo = try #require(model.runDemo(.en, stepInterval: .zero, holdBeforeFinish: .zero))
        await demo.value
        let state = DictationDisplayState(model: model)
        #expect(state.phase == .result)
        #expect(state.transcript == AppModel.DemoLocale.en.steps.last)
    }

    @Test(arguments: [(26, ControlPermissionPane.accessibility), (27, .deviceControl), (28, .deviceControl)])
    func controlPaneFollowsOSVersion(version: Int, expected: ControlPermissionPane) {
        #expect(ControlPermissionPane(osMajorVersion: version) == expected)
    }

    @Test func readinessCountsOnlyActionableGaps() {
        #expect(SetupReadiness(hasKey: true, microphone: .granted, controlGranted: true).missingCount == 0)
        #expect(SetupReadiness(hasKey: true, microphone: .notDetermined, controlGranted: true).missingCount == 0)
        #expect(SetupReadiness(hasKey: false, microphone: .denied, controlGranted: false).missingCount == 3)
    }
}

// MARK: Timeouts

@MainActor @Suite(.timeLimit(.minutes(1))) struct TimeoutTests {
    /// Time is the behavior under test: a restart postpones the action, and stop cancels it.
    @Test func countdownFiresOnceAfterTheLastRestart() async throws {
        let countdown = IdleCountdown()
        let fired = AsyncStream<ContinuousClock.Instant>.makeStream()
        let start = ContinuousClock.now
        countdown.restart(after: .milliseconds(300)) { Issue.record("a replaced countdown fired") }
        try await Task.sleep(for: .milliseconds(150))
        countdown.restart(after: .milliseconds(300)) { fired.continuation.yield(.now) }
        var iterator = fired.stream.makeAsyncIterator()
        let at = try #require(await iterator.next())
        #expect(at - start >= .milliseconds(450))
        let stopped = IdleCountdown()
        stopped.restart(after: .milliseconds(50)) { Issue.record("a stopped countdown fired") }
        stopped.stop()
        try await Task.sleep(for: .milliseconds(200))
    }

    @Test func timeoutsDefaultToThirtySecondsAndZeroTurnsThemOff() {
        #expect(AppModel.limit(30) == .seconds(30))
        #expect(AppModel.limit(0) == nil)
        #expect(AppModel.timeoutChoices.contains(30))
        #expect(SettingsView.timeoutLabel(0) == String(localized: "끄기"))
    }
}

// MARK: Hit areas

/// Overlay buttons are drawn small to fit the notch row, but each must still offer a 28 pt target.
@MainActor @Suite struct OverlayHitAreaTests {
    private func measuredSize(_ shape: OverlayControlStyle.Shape, _ label: some View) -> CGSize {
        let view = NSHostingView(rootView: Button {} label: { label }
            .buttonStyle(OverlayControlStyle(shape: shape, prominent: false)))
        view.layoutSubtreeIfNeeded()
        return view.fittingSize
    }

    @Test func iconButtonIsAtLeast28PointsSquare() {
        let size = measuredSize(.circle, Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)))
        #expect(size.width >= NotchOverlayGeometry.minimumHitSize)
        #expect(size.height >= NotchOverlayGeometry.minimumHitSize)
    }

    @Test func textButtonIsAtLeast28PointsTall() {
        let size = measuredSize(.capsule, Label("Copy", systemImage: "doc.on.doc").font(.callout.weight(.medium)))
        #expect(size.height >= NotchOverlayGeometry.minimumHitSize)
        #expect(size.width >= NotchOverlayGeometry.minimumHitSize)
    }
}
