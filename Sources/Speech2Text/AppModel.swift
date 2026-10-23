import AppKit
import DictationSpeech
import Observation

/// A finished dictation kept for the overlay's history list. Kept in memory only.
struct DictationRecord: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

@MainActor @Observable
final class AppModel {
    static let historyLimit = 20
    /// Finished dictations, newest first. The newest is also `transcript` until a new dictation replaces it.
    private(set) var history: [DictationRecord] = []
    let speech = SpeechEngine()
    private let insertion = TextInsertion()
    @ObservationIgnored private var live: LiveTyper?
    @ObservationIgnored private var awaitingTarget = false
    /// Audio time (ms) when the user moved on: a key, click or focus change. Words whose sound started before it
    /// are never typed into another field, however late they are recognized; only later words go to the field the
    /// user settles in. Nil while the first field is still in use.
    @ObservationIgnored private var cutMs: Int?
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
    /// Choices for the two automatic timeouts, in seconds; 0 turns one off.
    static let timeoutChoices = [0, 10, 15, 20, 30, 45, 60, 120, 180, 300]
    /// A recording with no newly recognized speech for this long finishes by itself.
    var silenceStopSeconds = UserDefaults.standard.object(forKey: "silenceStopSeconds") as? Int ?? 30 {
        didSet {
            UserDefaults.standard.set(silenceStopSeconds, forKey: "silenceStopSeconds")
            speech.silenceLimit = Self.limit(silenceStopSeconds)
        }
    }
    /// The overlay closes by itself after this long without dictation or any change on it.
    var overlayAutoCloseSeconds = UserDefaults.standard.object(forKey: "overlayAutoCloseSeconds") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(overlayAutoCloseSeconds, forKey: "overlayAutoCloseSeconds") }
    }
    var overlayAutoCloseLimit: Duration? { Self.limit(overlayAutoCloseSeconds) }
    static func limit(_ seconds: Int) -> Duration? { seconds > 0 ? .seconds(seconds) : nil }
    private(set) var dictionary = AppModel.storedDictionary() {
        didSet {
            UserDefaults.standard.set(dictionary, forKey: "dictionaryTerms")
            speech.vocabulary = recognitionTerms
        }
    }
    /// The command phrase goes to Soniox as context too; without it "엔터" after a pause is often heard as "센터".
    private var recognitionTerms: [String] {
        spokenEnter.map { $0.terms.reduce(dictionary) { DictionaryTerms.adding($1, to: $0) } } ?? dictionary
    }
    private var spokenEnter: SpokenEnter? {
        spokenEnterEnabled ? SpokenEnter(setting: spokenEnterPhrase, shownDefault: String(localized: "엔터 보내기")) : nil
    }
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
        speech.silenceLimit = Self.limit(silenceStopSeconds)
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
        case .userEdited:
            moveOn(at: live.userActedAt ?? ProcessInfo.processInfo.systemUptime)
        case .targetChanged:
            // A focus change without a key or click (another app took focus) is only noticed now.
            moveOn(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Never retype into the old spot; speech after `uptime` goes to the field the user settles in.
    private func moveOn(at uptime: TimeInterval) {
        live = nil
        cutMs = speech.audioMilliseconds(atUptime: uptime) ?? Int.max
        awaitingTarget = true
        feedback = String(localized: "입력 위치가 바뀌었어요. 입력 칸에 커서를 두고 말하면 그 칸에 이어서 써요.")
    }

    private func pending(_ text: String) -> String {
        cutMs.map { LiveTextEdit.continuation(of: text, after: speech.transcript(spokenBefore: $0)) } ?? text
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
        if !empty {
            history.insert(DictationRecord(text: text), at: 0)
            if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        }
        // A key or click while the last words were being finalized counts like one during recording.
        if let live, let acted = live.userActedAt { moveOn(at: acted) }
        let movedOn = cutMs != nil
        let rest = pending(text)
        if live == nil, awaitingTarget, !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = acquireLiveTarget()
        }
        awaitingTarget = false
        cutMs = nil
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
        } else if movedOn, !empty {
            feedback = String(localized: "입력 위치가 바뀔 때까지 한 말은 다른 칸에 넣지 않았어요. 복사하거나 붙여넣어 주세요.")
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
        cutMs = nil
        feedback = ""
        guard autoInsert else { return }
        guard accessibilityGranted else {
            feedback = String(localized: "'\(ControlPermissionPane.current.title)' 권한이 없어 결과를 보관해요.")
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
        cutMs = nil
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
    func copyHistory(_ record: DictationRecord) {
        feedback = insertion.copy(record.text) ? String(localized: "복사했어요. 원하는 곳에서 ⌘V를 누르세요.") : String(localized: "복사할 텍스트가 없어요.")
    }
    func copyError() {
        feedback = insertion.copy(status) ? String(localized: "복사했어요. 원하는 곳에서 ⌘V를 누르세요.") : String(localized: "복사할 텍스트가 없어요.")
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
    /// An explicit Show wins over focused Settings, whose own button is pressed with Settings focused. Settings hides
    /// the overlay again only when it regains focus.
    func showOverlay() {
        overlayVisible = true
        settingsFocused = false
    }
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
    /// Settings only hides the overlay while the user is in it. Its window stays key when the user switches to
    /// another app, and no resign-key notice arrives, so app activation decides.
    func appActivationChanged(isActive: Bool, settingsIsKey: Bool) {
        settingsFocused = isActive && settingsIsKey
    }
}
