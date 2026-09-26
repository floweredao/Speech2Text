import AppKit
import DictationSpeech
import Observation

@MainActor @Observable
final class AppModel {
    let speech = SpeechEngine()
    private let insertion = TextInsertion()
    @ObservationIgnored private var live: LiveTyper?
    @ObservationIgnored private var awaitingTarget = false
    var feedback = ""
    var autoInsert = true
    var overlayVisible = true
    var accessibilityGranted = AXIsProcessTrusted()
    var settingsAction: (() -> Void)?
    var inputDeviceUID: String? = UserDefaults.standard.string(forKey: "inputDeviceUID") {
        didSet {
            UserDefaults.standard.set(inputDeviceUID, forKey: "inputDeviceUID")
            speech.inputDeviceUID = inputDeviceUID
        }
    }
    var transcript: String { speech.transcript }
    var status: String { speech.status }
    var isRecording: Bool { speech.isRecording }
    var isBusy: Bool { speech.isBusy }
    var speechPhase: SpeechPhase { speech.phase }
    var hasError: Bool { speech.hasError }
    var speechOutcome: SpeechOutcome { speech.outcome }
    var hasCurrentTranscript: Bool { speech.hasCurrentTranscript }
    var apiKey: String {
        get { speech.apiKey }
        set { speech.apiKey = newValue }
    }

    init() {
        speech.inputDeviceUID = inputDeviceUID
        speech.onLiveText = { [weak self] text in self?.mirror(text) }
        speech.onFinal = { [weak self] text in self?.complete(text) }
    }

    private func mirror(_ text: String) {
        if live == nil, awaitingTarget {
            guard acquireLiveTarget() else { return }
            feedback = "선택한 칸에 실시간으로 입력해요."
        }
        guard let live else { return }
        switch live.sync(text) {
        case .applied: break
        case .targetChanged:
            self.live = nil
            feedback = "입력 위치가 바뀌어 실시간 입력을 멈췄어요. 결과는 여기에 보관해요."
        case .failed:
            self.live = nil
            feedback = "이 칸에는 실시간 입력을 할 수 없어요. 결과는 여기에 보관해요."
        }
    }

    private func complete(_ text: String) {
        overlayVisible = true
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if live == nil, awaitingTarget, !empty { _ = acquireLiveTarget() }
        awaitingTarget = false
        if let live {
            self.live = nil
            switch live.sync(text) {
            case .applied: feedback = empty ? "인식된 음성이 없어 입력하지 않았어요." : "입력 칸에 받아쓰기를 입력했어요."
            case .targetChanged: feedback = "입력 위치가 바뀌어 마지막 수정을 넣지 못했어요. 복사하거나 붙여넣어 주세요."
            case .failed: feedback = "마지막 수정을 넣지 못했어요. 복사하거나 붙여넣어 주세요."
            }
        } else if empty {
            feedback = "인식된 음성이 없어 입력하지 않았어요."
        } else if feedback.isEmpty {
            feedback = "받아쓰기를 보관했어요. 입력 칸을 선택한 뒤 붙여넣어 주세요."
        }
    }

    private func prepareLiveTyping() {
        accessibilityGranted = insertion.isTrusted
        live = nil
        awaitingTarget = false
        feedback = ""
        guard autoInsert else { return }
        guard accessibilityGranted else {
            feedback = "기기 제어 권한이 없어 결과를 보관해요."
            return
        }
        // Started from our own settings window: give focus back to the app the user was typing in.
        if NSApp.isActive { NSApp.deactivate() }
        if acquireLiveTarget() {
            feedback = "선택한 칸에 실시간으로 입력해요."
        } else {
            awaitingTarget = true
            feedback = "입력할 칸을 클릭하면 그 칸에 바로 써요."
        }
    }

    private func acquireLiveTarget() -> Bool {
        guard let target = insertion.currentTarget(), insertion.isEditable(target) else { return false }
        live = LiveTyper(target: target, insertion: insertion)
        awaitingTarget = false
        return true
    }

    func toggleRecording() {
        overlayVisible = true
        if isRecording { speech.finish() }
        else if !isBusy {
            prepareLiveTyping()
            speech.start()
        }
    }
    func cancel() {
        guard isBusy else { return }
        let hadTyped = !(live?.typed.isEmpty ?? true)
        let removed = hadTyped && live?.sync("") == .applied
        live = nil
        awaitingTarget = false
        speech.cancel()
        feedback = removed ? "취소해서 입력하던 내용을 지웠어요." : "취소했어요. 입력하지 않았어요."
    }
    func transcribeFile(_ url: URL) {
        guard !isBusy else { return }
        overlayVisible = true
        prepareLiveTyping()
        speech.start(audioFile: url)
    }
    func copyTranscript() {
        feedback = insertion.copy(transcript) ? "복사했어요. 원하는 곳에서 ⌘V를 누르세요." : "복사할 텍스트가 없어요."
    }
    func pasteTranscript() {
        guard !isBusy else {
            feedback = "받아쓰기를 마무리한 다음 붙여넣어 주세요."
            return
        }
        accessibilityGranted = insertion.isTrusted
        feedback = insertion.insert(transcript, expected: nil)
    }
    func dismissOverlay() { overlayVisible = false }
    func requestAccessibility() {
        insertion.requestPermission()
        accessibilityGranted = insertion.isTrusted
    }
    func saveKey() { Task { await speech.saveKey() } }
    func loadKey() { Task { await speech.loadKey() } }
    func openSettings() { settingsAction?() }
}
