import CoreGraphics
import DictationSpeech
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
        #expect(NotchOverlayGeometry.transcriptViewportHeight(textHeight: 19) == 19)
        #expect(NotchOverlayGeometry.transcriptViewportHeight(textHeight: 400)
                == NotchOverlayGeometry.maxTranscriptHeight)
        #expect(NotchOverlayGeometry.transcriptViewportHeight(textHeight: -5) == 0)
    }

    @Test func draggedPanelKeepsItsTopCenterWhileHeightChanges() {
        let anchor = CGPoint(x: 400, y: 600)
        let compact = NotchOverlayGeometry.frame(anchor: anchor, screen: notchScreen, expanded: false,
                                                 contentHeight: 0)
        let expanded = NotchOverlayGeometry.frame(anchor: anchor, screen: notchScreen, expanded: true,
                                                  contentHeight: 180)
        for frame in [compact, expanded] {
            #expect(frame.midX == anchor.x)
            #expect(frame.maxY == anchor.y)
        }
        #expect(expanded.height == 180)
    }

    @Test func draggedPanelStaysOnScreenNearEdges() {
        let corner = NotchOverlayGeometry.frame(anchor: CGPoint(x: 10, y: 20), screen: notchScreen,
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

    @Test func errorMidRecordingMarksPartialTextUnfinished() {
        let state = display(.idle, error: true, transcript: live, session: session(.failed, current: true))
        #expect(state.retained == live)
        #expect(state.retainedKind == .unfinished)
        #expect(state.transcript.isEmpty)
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
