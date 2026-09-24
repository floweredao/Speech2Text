import AppKit
import DictationSpeech
import Observation

@MainActor @Observable
final class AppModel {
    let speech = SpeechEngine()
    private let insertion = TextInsertion()
    private var target: TextInsertion.Target?
    var feedback = ""
    var autoInsert = true
    var overlayVisible = true
    var accessibilityGranted = AXIsProcessTrusted()
    var settingsAction: (() -> Void)?
    var transcript: String { speech.transcript }
    var status: String { speech.status }
    var isRecording: Bool { speech.isRecording }
    var isBusy: Bool { speech.isBusy }
    var speechPhase: SpeechPhase { speech.phase }
    var hasError: Bool { speech.hasError }
    var apiKey: String {
        get { speech.apiKey }
        set { speech.apiKey = newValue }
    }

    init() {
        speech.onFinal = { [weak self] text in
            guard let self else { return }
            self.overlayVisible = true
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.feedback = "인식된 음성이 없어 입력하지 않았어요."
                self.target = nil
                return
            }
            if self.autoInsert, let target = self.target {
                self.feedback = self.insertion.insert(text, expected: target)
            } else {
                self.feedback = "받아쓰기를 보관했어요. 입력 칸을 선택한 뒤 붙여넣어 주세요."
            }
            self.target = nil
        }
    }
    func toggleRecording() {
        overlayVisible = true
        accessibilityGranted = insertion.isTrusted
        if isRecording { speech.finish() }
        else if !isBusy {
            target = insertion.currentTarget()
            feedback = ""
            speech.start()
        }
    }
    func cancel() {
        speech.cancel()
        target = nil
        feedback = "취소했어요. 자동으로 입력하지 않았어요."
    }
    func transcribeFile(_ url: URL) {
        guard !isBusy else { return }
        target = insertion.currentTarget()
        overlayVisible = true
        feedback = ""
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
    func importSourceKey() { Task { await speech.importSourceKey() } }
    func openSettings() { settingsAction?() }
}
