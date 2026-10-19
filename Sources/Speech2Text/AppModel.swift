import AppKit
import DictationSpeech
import Observation

@MainActor @Observable
final class AppModel {
    let speech = SpeechEngine()
    private let insertion = TextInsertion()
    @ObservationIgnored private var live: LiveTyper?
    @ObservationIgnored private var awaitingTarget = false
    /// Recognized text at the moment live typing stopped because the user moved on. Only text after it is typed
    /// into the field the user settles in next; nil while the first field is still in use.
    @ObservationIgnored private var resumeBase: String?
    /// Recognized text as of the previous live update. A click or focus change is only noticed on the next update,
    /// whose new words were spoken in the new field, so the resume point is the text heard before it.
    @ObservationIgnored private var heard = ""
    var feedback = ""
    var autoInsert = true
    private(set) var overlayRequested = true
    var settingsFocused = false
    var overlayVisible: Bool {
        get { overlayRequested && !settingsFocused }
        set { overlayRequested = newValue }
    }
    var accessibilityGranted = AXIsProcessTrusted() {
        didSet { if accessibilityGranted, !oldValue { shortcutsChanged?() } }
    }
    var settingsAction: (() -> Void)?
    var shortcuts = ShortcutSettings.load() {
        didSet {
            shortcuts.save()
            shortcutsChanged?()
        }
    }
    /// While set, global shortcuts are paused so the settings window can record keys.
    var capturingShortcut: ShortcutAction? {
        didSet { if capturingShortcut != oldValue { shortcutsChanged?() } }
    }
    var shortcutPreview = ""
    var shortcutNote = ""
    var shortcutProblem = ""
    @ObservationIgnored var shortcutsChanged: (() -> Void)?
    var inputDeviceUID: String? = UserDefaults.standard.string(forKey: "inputDeviceUID") {
        didSet {
            UserDefaults.standard.set(inputDeviceUID, forKey: "inputDeviceUID")
            speech.inputDeviceUID = inputDeviceUID
        }
    }
    var spokenEnterEnabled = UserDefaults.standard.object(forKey: "spokenEnterEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(spokenEnterEnabled, forKey: "spokenEnterEnabled")
            speech.vocabulary = recognitionTerms
        }
    }
    var spokenEnterPhrase = UserDefaults.standard.string(forKey: "spokenEnterPhrase") ?? String(localized: "엔터 보내기") {
        didSet {
            UserDefaults.standard.set(spokenEnterPhrase, forKey: "spokenEnterPhrase")
            speech.vocabulary = recognitionTerms
        }
    }
    private(set) var dictionary = AppModel.storedDictionary() {
        didSet {
            UserDefaults.standard.set(dictionary, forKey: "dictionaryTerms")
            speech.vocabulary = recognitionTerms
        }
    }
    /// The command phrase goes to Soniox as context too; without it "엔터" after a pause is often heard as "센터".
    private var recognitionTerms: [String] {
        spokenEnterEnabled ? DictionaryTerms.adding(spokenEnterPhrase, to: dictionary) : dictionary
    }
    private var spokenEnter: SpokenEnter? { spokenEnterEnabled ? SpokenEnter(phrase: spokenEnterPhrase) : nil }
    /// Kept current by a CoreAudio listener, so Settings reflects plugged-in or removed microphones at once.
    private(set) var inputDevices = AudioInputDevices.all()
    private(set) var defaultInputDevice = AudioInputDevices.defaultDevice()
    @ObservationIgnored private var deviceObservation: AudioInputDevicesObservation?
    var transcript: String { withoutEnterCommand(speech.transcript) }
    var status: String { speech.status }
    var isRecording: Bool { speech.isRecording }
    var isBusy: Bool { speech.isBusy }
    var speechPhase: SpeechPhase { speech.phase }
    var hasError: Bool { speech.hasError }
    var needsSettings: Bool { speech.needsSettings }
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
        speech.onTurnFinal = { [weak self] text in self?.turnFinalized(text) }
        speech.vocabulary = recognitionTerms
        deviceObservation = AudioInputDevices.observe { [weak self] in self?.refreshInputDevices() }
    }

    private static func storedDictionary() -> [String] {
        let defaults = UserDefaults.standard
        if let terms = defaults.stringArray(forKey: "dictionaryTerms") { return terms }
        if let lines = defaults.string(forKey: "vocabulary") { return DictionaryTerms.migrating(lines: lines) }
        return DictionaryTerms.standard
    }

    func addDictionaryTerms(_ input: String) { dictionary = DictionaryTerms.adding(input, to: dictionary) }
    func removeDictionaryTerm(_ term: String) { dictionary.removeAll { $0 == term } }

    func refreshInputDevices() {
        inputDevices = AudioInputDevices.all()
        defaultInputDevice = AudioInputDevices.defaultDevice()
    }

    private func mirror(_ text: String) {
        let heardBefore = heard
        heard = text
        if live == nil, awaitingTarget {
            guard acquireLiveTarget() else { return }
            feedback = String(localized: "선택한 칸에 실시간으로 입력해요.")
        }
        guard let live else { return }
        let outcome = live.sync(pending(withoutEnterCommand(text)))
        switch outcome {
        case .applied: break
        case .failed:
            self.live = nil
            feedback = String(localized: "이 칸에는 실시간 입력을 할 수 없어요. 결과는 여기에 보관해요.")
        case .targetChanged, .userEdited:
            // Never retype into the old spot; speech after this point goes to the field the user settles in.
            self.live = nil
            resumeBase = heardBefore
            awaitingTarget = true
            feedback = String(localized: "입력 위치가 바뀌었어요. 입력 칸에 커서를 두고 말하면 그 칸에 이어서 써요.")
        }
    }

    private func pending(_ text: String) -> String {
        resumeBase.map { LiveTextEdit.continuation(of: text, after: $0) } ?? text
    }

    private func withoutEnterCommand(_ text: String) -> String {
        spokenEnter?.strip(text) ?? text
    }

    /// The command only counts once Soniox has finalized it after a pause, so a phrase mid-sentence never stops dictation.
    private func turnFinalized(_ text: String) {
        if spokenEnter?.strip(text) != nil { speech.finish() }
    }

    private func complete(_ spoken: String) {
        overlayVisible = true
        let command = spokenEnter?.strip(spoken)
        let text = command ?? spoken
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let rest = pending(text)
        if live == nil, awaitingTarget, !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = acquireLiveTarget()
        }
        awaitingTarget = false
        resumeBase = nil
        heard = ""
        if let live {
            self.live = nil
            switch live.sync(rest) {
            case .applied where command != nil:
                feedback = live.pressReturn() ? String(localized: "입력하고 엔터를 눌렀어요.")
                    : String(localized: "입력 칸이 바뀌어 엔터는 누르지 않았어요.")
            case .applied: feedback = empty ? String(localized: "인식된 음성이 없어 입력하지 않았어요.") : String(localized: "입력 칸에 받아쓰기를 입력했어요.")
            case .targetChanged: feedback = String(localized: "입력 위치가 바뀌어 마지막 수정을 넣지 못했어요. 복사하거나 붙여넣어 주세요.")
            case .failed: feedback = String(localized: "마지막 수정을 넣지 못했어요. 복사하거나 붙여넣어 주세요.")
            case .userEdited: feedback = String(localized: "입력 칸을 직접 건드려서 마지막 수정을 넣지 못했어요. 복사하거나 붙여넣어 주세요.")
            }
        } else if command != nil {
            feedback = String(localized: "입력 중인 칸이 없어 엔터는 누르지 않았어요.")
        } else if empty {
            feedback = String(localized: "인식된 음성이 없어 입력하지 않았어요.")
        } else if feedback.isEmpty {
            feedback = String(localized: "받아쓰기를 보관했어요. 입력 칸을 선택한 뒤 붙여넣어 주세요.")
        }
    }

    /// A start the engine will refuse (no key, offline) must not take focus from Settings or claim live typing.
    private func startLiveTypingIfAdmitted() {
        if speech.refusesStart {
            live = nil
            awaitingTarget = false
            feedback = ""
        } else {
            prepareLiveTyping()
        }
    }

    private func prepareLiveTyping() {
        accessibilityGranted = insertion.isTrusted
        live = nil
        awaitingTarget = false
        resumeBase = nil
        heard = ""
        feedback = ""
        guard autoInsert else { return }
        guard accessibilityGranted else {
            feedback = String(localized: "기기 제어 권한이 없어 결과를 보관해요.")
            return
        }
        // Started from our own settings window: give focus back to the app the user was typing in.
        if NSApp.isActive { NSApp.deactivate() }
        if acquireLiveTarget() {
            feedback = String(localized: "선택한 칸에 실시간으로 입력해요.")
        } else {
            awaitingTarget = true
            feedback = String(localized: "입력할 칸을 클릭하면 그 칸에 바로 써요.")
        }
    }

    private func acquireLiveTarget() -> Bool {
        guard let target = insertion.currentTarget(), insertion.isEditable(target) else { return false }
        live = LiveTyper(target: target, insertion: insertion) { [weak self] chord in
            self?.shortcuts.bindings.keys.contains { $0.trigger == .key(chord) } ?? false
        }
        awaitingTarget = false
        return true
    }

    func toggleRecording() {
        overlayVisible = true
        if isRecording { speech.finish() }
        else if !isBusy {
            startLiveTypingIfAdmitted()
            speech.start()
        }
    }
    func cancel() {
        guard isBusy else { return }
        let hadTyped = !(live?.typed.isEmpty ?? true)
        let removed = hadTyped && live?.sync("") == .applied
        live = nil
        awaitingTarget = false
        resumeBase = nil
        heard = ""
        speech.cancel()
        feedback = removed ? String(localized: "취소해서 입력하던 내용을 지웠어요.")
            : hadTyped ? String(localized: "취소했어요. 이미 입력한 글자는 지우지 못했어요.")
            : String(localized: "취소했어요. 입력하지 않았어요.")
    }
    func transcribeFile(_ url: URL) {
        guard !isBusy else { return }
        overlayVisible = true
        startLiveTypingIfAdmitted()
        speech.start(audioFile: url)
    }
    func copyTranscript() {
        feedback = insertion.copy(transcript) ? String(localized: "복사했어요. 원하는 곳에서 ⌘V를 누르세요.") : String(localized: "복사할 텍스트가 없어요.")
    }
    func pasteTranscript() {
        guard !isBusy else {
            feedback = String(localized: "받아쓰기를 마무리한 다음 붙여넣어 주세요.")
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
    func deleteKey() { Task { await speech.deleteKey() } }
    func openSettings() {
        settingsFocused = true
        settingsAction?()
    }
}
