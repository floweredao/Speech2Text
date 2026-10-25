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
    var feedback = "" {
        didSet { feedbackIsRoutine = false }
    }
    /// The feedback only confirms that things went as expected (typing live, typed in), so the overlay keeps it out
    /// of sight; problems and voice edits stay visible.
    private(set) var feedbackIsRoutine = false
    /// Overrides the microphone authorization state in Settings for synthetic demo/capture runs.
    var microphoneAccessOverride: MicrophoneAccess?
    /// The app live typing writes into, shown beside the title.
    private(set) var liveTargetName: String?
    /// The icon of that app, shown beside its name so the destination reads at a glance.
    private(set) var liveTargetIcon: NSImage?
    /// Language codes offered for the experimental live translation; nil types the spoken language.
    static let translationChoices: [String?] = [nil, "en", "ko", "ja", "zh"]
    var translationTarget = UserDefaults.standard.string(forKey: "translationTarget") {
        didSet {
            UserDefaults.standard.set(translationTarget, forKey: "translationTarget")
            speech.translationTarget = translationTarget
        }
    }
    /// Marks words Soniox was unsure of in the overlay.
    var marksUncertainWords = UserDefaults.standard.object(forKey: "marksUncertainWords") as? Bool ?? false {
        didSet { UserDefaults.standard.set(marksUncertainWords, forKey: "marksUncertainWords") }
    }
    static let uncertainBelow = 0.6
    var uncertainWords: [String] {
        marksUncertainWords && speech.hasCurrentTranscript ? speech.uncertainTokens(below: Self.uncertainBelow) : []
    }
    var inputLevel: Float { speech.inputLevel }
    var autoInsert = true
    /// Diagnostic for `--audio-file`: print each recognized turn with the pause before it, then quit.
    var printsTurnsAndQuits = false
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
        if let contextTermsOverride { return contextTermsOverride }
        let commands = (spokenEnter?.terms ?? []) + (voiceEditingEnabled ? VoiceCommand.terms : [])
            + (judgeMode == .trigger ? trigger.terms : [])
            + (wakeListeningEnabled ? wakeSpoken.terms : [])
        return (commands + addedContextTerms).reduce(dictionary) { DictionaryTerms.adding($1, to: $0) }
    }
    /// Placeholders until the owner settles on the app's name and the trigger word; Settings can change both.
    /// The on-device model hears real English words far better than made-up names (DESIGN.md, "호출어").
    nonisolated static let defaultWakePhrase = "Hey Computer"
    nonisolated static let defaultWakeSpellings = ["헤이 컴퓨터"]
    /// How macOS's on-device Korean recognizer writes "Hey Computer" said the Korean way: the "hey" comes out as any of
    /// these words (measured on the system's Korean voices). Only the idle wake check uses them; the dictation keeps
    /// `defaultWakeSpellings`, because "회의 컴퓨터" in the middle of a dictation is ordinary speech.
    nonisolated static let defaultWakeSoundAlikes: [String] = {
        let hey = ["헤이", "해이", "에이", "애이", "제이", "게이", "케이", "회의", "hey", "hay", "kay", "hake"]
        let computer = ["컴퓨터", "컴퓨타", "컴부터", "computer"]
        return hey.flatMap { first in computer.map { "\(first) \($0)" } }
    }()

    /// Whether words the system recognizer wrote while idle hold `phrase` (with its sound-alikes for the default).
    nonisolated static func wakeMatcher(for phrase: String) -> @Sendable (String) -> Bool {
        let isDefault = phrase.trimmingCharacters(in: .whitespaces).lowercased() == defaultWakePhrase.lowercased()
        let spoken = SpokenPhrase(phrase, alternates: isDefault ? defaultWakeSpellings + defaultWakeSoundAlikes : [])
        return { spoken.split($0) != nil }
    }
    static let defaultTriggerWord = "자비스"
    /// Starts dictation when heard while idle and finishes it when said at the end of a dictation. Only a phrase
    /// changed from the default is stored, so a new default (the app's final name) reaches everyone who kept it.
    var wakePhrase = UserDefaults.standard.string(forKey: "wakePhrase") ?? AppModel.defaultWakePhrase {
        didSet {
            Self.storeUnlessDefault(wakePhrase, Self.defaultWakePhrase, key: "wakePhrase")
            speech.vocabulary = recognitionTerms
            syncWakeListening()
        }
    }
    /// The wake phrase as dictation may write it.
    var wakeSpoken: SpokenPhrase {
        let isDefault = wakePhrase.trimmingCharacters(in: .whitespaces).lowercased() == Self.defaultWakePhrase.lowercased()
        return SpokenPhrase(wakePhrase, alternates: isDefault ? Self.defaultWakeSpellings : [])
    }
    /// Said right before a voice command ("<trigger> 지워") so the command is not taken for dictated words.
    var triggerWord = UserDefaults.standard.string(forKey: "triggerWord") ?? AppModel.defaultTriggerWord {
        didSet {
            Self.storeUnlessDefault(triggerWord, Self.defaultTriggerWord, key: "triggerWord")
            speech.vocabulary = recognitionTerms
        }
    }
    var trigger: SpokenPhrase { SpokenPhrase(triggerWord) }
    private static func storeUnlessDefault(_ value: String, _ standard: String, key: String) {
        let custom = value.trimmingCharacters(in: .whitespacesAndNewlines) != standard
        UserDefaults.standard.set(custom ? value : nil, forKey: key)
    }
    /// Keeps the microphone open while idle and starts dictation on the wake phrase; saying it at the end of a
    /// dictation finishes it. Off unless the user turns it on.
    var wakeListeningEnabled = UserDefaults.standard.bool(forKey: "wakeListeningEnabled") {
        didSet {
            UserDefaults.standard.set(wakeListeningEnabled, forKey: "wakeListeningEnabled")
            speech.vocabulary = recognitionTerms
            syncWakeListening()
        }
    }
    var wakeSensitivity = UserDefaults.standard.string(forKey: "wakeSensitivity").flatMap(WakeSensitivity.init) ?? .standard {
        didSet {
            UserDefaults.standard.set(wakeSensitivity.rawValue, forKey: "wakeSensitivity")
            syncWakeListening()
        }
    }
    /// Why listening for the wake phrase is not running although it is on; nil when it runs or is off.
    private(set) var wakeProblem: String?
    private(set) var isListeningForWake = false
    /// Runs when the wake phrase is heard while idle; starts dictation when unset.
    @ObservationIgnored var onWake: (() -> Void)?
    @ObservationIgnored private var wakeListener: WakeWordListener?
    @ObservationIgnored private var wakeAllowed = false
    /// How a spoken edit is told from dictated words; `.off` types everything. Settings written before this choice
    /// existed keep their voice-editing switch: on is the trigger word, off is off.
    var commandJudge = UserDefaults.standard.string(forKey: "commandJudge").flatMap(CommandJudgeMode.init)
        ?? (UserDefaults.standard.object(forKey: "voiceEditingEnabled") as? Bool == false ? .off : .trigger) {
        didSet {
            UserDefaults.standard.set(commandJudge.rawValue, forKey: "commandJudge")
            speech.vocabulary = recognitionTerms
        }
    }
    /// Diagnostics (`--command-judge`) use another mode for one run without changing the setting.
    @ObservationIgnored var commandJudgeOverride: CommandJudgeMode? {
        didSet { speech.vocabulary = recognitionTerms }
    }
    private var judgeMode: CommandJudgeMode { commandJudgeOverride ?? commandJudge }
    /// Diagnostics (`--context-terms`) send these Soniox context terms (none when empty) for one run.
    @ObservationIgnored var contextTermsOverride: [String]? {
        didSet { speech.vocabulary = recognitionTerms }
    }
    /// Diagnostics (`--add-context-terms`) send these after the usual terms for one run.
    @ObservationIgnored var addedContextTerms: [String] = [] {
        didSet { speech.vocabulary = recognitionTerms }
    }
    var punctuationStyle = UserDefaults.standard.string(forKey: "punctuationStyle").flatMap(PunctuationStyle.init) ?? .asIs {
        didSet { UserDefaults.standard.set(punctuationStyle.rawValue, forKey: "punctuationStyle") }
    }
    var voiceEditingEnabled: Bool { judgeMode != .off }
    /// The Jev API key from this app's Keychain.
    var jevKey = ""
    private(set) var jevKeyMessage = ""
    /// Diagnostics (`--jev-key-file`) use another key for one run without storing it.
    @ObservationIgnored var jevKeyOverride: String?
    @ObservationIgnored var jevJudge = JevJudge()
    /// Observed: `transcript` reads Jev's verdicts, so a late answer must redraw the overlay as it retypes the field.
    private var verdicts: [String: CommandVerdict] = [:]
    @ObservationIgnored private var judgeTasks: [String: Task<Void, Never>] = [:]
    /// Jev's answers in this dictation, printed by `--print-turns`.
    @ObservationIgnored private var judgeLog: [(CommandQuestion, JudgeAnswer)] = []
    /// The dictation ended while Jev was still deciding; it completes when the last answer arrives.
    @ObservationIgnored private var completionPending = false
    private var unansweredAsText = false
    /// Commands already reported for the current field, so each one is announced once.
    @ObservationIgnored private var reportedEdits = 0
    private var spokenEnter: SpokenEnter? {
        spokenEnterEnabled
            ? SpokenEnter(setting: spokenEnterPhrase, shownDefault: String(localized: "엔터 보내기"),
                          trigger: judgeMode == .jev ? nil : trigger) : nil
    }
    /// Kept current by a CoreAudio listener, so Settings reflects plugged-in or removed microphones at once.
    private(set) var inputDevices = AudioInputDevices.all()
    private(set) var defaultInputDevice = AudioInputDevices.defaultDevice()
    @ObservationIgnored private var deviceObservation: AudioInputDevicesObservation?
    /// The dictation as it reads after voice edits; an earlier result when this run has no text of its own.
    var transcript: String {
        let raw = speech.transcript
        return withoutEnterCommand(speech.hasCurrentTranscript ? edited(from: nil).text : raw)
    }
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
        speech.translationTarget = translationTarget
        deviceObservation = AudioInputDevices.observe { [weak self] in self?.refreshInputDevices() }
        observeBusy()
    }

    /// Wake listening starts only once the app runs normally, never for a file transcription or in tests.
    func beginWakeListening() {
        wakeAllowed = true
        syncWakeListening()
    }

    /// Whether the idle microphone should listen for the wake phrase. Never while dictating: the dictation itself
    /// hears the phrase (as a command prefix), and two listeners would start a second dictation over the first.
    nonisolated static func listensForWake(enabled: Bool, phraseIsUsable: Bool, isBusy: Bool) -> Bool {
        enabled && phraseIsUsable && !isBusy
    }

    private func observeBusy() {
        withObservationTracking { _ = speech.isBusy } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncWakeListening()
                self?.observeBusy()
            }
        }
    }

    /// The model's word pieces for the phrase; nil when the phrase cannot be listened for.
    var wakePieces: [String]? { listener()?.tokenizer.pieces(for: wakePhrase) }

    private func listener() -> WakeWordListener? {
        if let wakeListener { return wakeListener }
        guard let model = Bundle.main.url(forResource: "WakeWord", withExtension: nil),
              let listener = try? WakeWordListener(model: model) else { return nil }
        listener.onWake = { [weak self] in self?.wakeHeard() }
        listener.onFailure = { [weak self] message in
            self?.isListeningForWake = false
            self?.wakeProblem = message
        }
        wakeListener = listener
        return listener
    }

    private func syncWakeListening() {
        guard wakeAllowed, wakeListeningEnabled else {
            wakeListener?.stop()
            isListeningForWake = false
            wakeProblem = nil
            return
        }
        guard let listener = listener() else {
            isListeningForWake = false
            wakeProblem = String(localized: "호출어 모델을 찾지 못했어요. 앱을 다시 설치해 주세요.")
            return
        }
        let pieces = listener.tokenizer.pieces(for: wakePhrase)
        guard Self.listensForWake(enabled: true, phraseIsUsable: pieces != nil, isBusy: isBusy), let pieces else {
            listener.stop()
            isListeningForWake = false
            wakeProblem = pieces == nil ? String(localized: "호출어는 영어 글자로 적어 주세요.") : nil
            return
        }
        let config = WakeConfig(pieces: pieces, sensitivity: wakeSensitivity, deviceUID: inputDeviceUID)
        guard !listener.isListening || config != wakeConfig else { return }
        wakeConfig = config
        wakeProblem = nil
        isListeningForWake = true
        listener.start(pieces: pieces, sensitivity: wakeSensitivity, deviceUID: inputDeviceUID,
                       spoken: Self.wakeMatcher(for: wakePhrase))
    }

    private struct WakeConfig: Equatable {
        let pieces: [String]
        let sensitivity: WakeSensitivity
        let deviceUID: String?
    }
    @ObservationIgnored private var wakeConfig: WakeConfig?

    /// The idle microphone is released before dictation opens its own, so the phrase is not heard twice.
    private func wakeHeard() {
        wakeListener?.stop()
        isListeningForWake = false
        if let onWake { onWake() } else { handle(.start) }
        syncWakeListening()
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
        if wakeProblem != nil { syncWakeListening() }
    }

    private func mirror(_: String) {
        let field = edited(from: cutMs)
        let note = Self.editNote(feedback, reported: reportedEdits, field: field, undo: undoPhrase)
        if note != feedback { feedback = note }
        reportedEdits = field.outcomes.count
        if live == nil, awaitingTarget {
            guard acquireLiveTarget() else { return }
            routine(String(localized: "선택한 칸에 실시간으로 입력해요."))
        }
        guard let live else { return }
        let outcome = live.sync(withoutEnterCommand(field.text))
        switch outcome {
        case .applied: break
        case .failed:
            self.live = nil
            liveTargetName = nil
            liveTargetIcon = nil
            feedback = String(localized: "이 칸에는 실시간 입력을 할 수 없어요. 결과는 여기에 보관해요.")
        case .userEdited:
            moveOn(at: live.userActedAt ?? ProcessInfo.processInfo.systemUptime)
        case .targetChanged:
            // A focus change without a key or click (another app took focus) is only noticed now.
            moveOn(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Never retype into the old spot; speech after `uptime` goes to the field the user settles in.
    private func routine(_ text: String) {
        feedback = text
        feedbackIsRoutine = true
    }

    private func moveOn(at uptime: TimeInterval) {
        live = nil
        liveTargetName = nil
        liveTargetIcon = nil
        cutMs = speech.audioMilliseconds(atUptime: uptime) ?? Int.max
        awaitingTarget = true
        feedback = String(localized: "입력 위치가 바뀌었어요. 입력 칸에 커서를 두고 말하면 그 칸에 이어서 써요.")
    }

    /// The text for the field in use: words spoken after `cut` (all when nil), with voice edits applied.
    private func edited(from cut: Int?) -> VoiceEditor.Result {
        let gate: VoiceEditor.Gate = switch judgeMode {
        case .off: .off
        case .trigger: .trigger(trigger)
        case .jev: .judged(verdicts, unanswered: unansweredAsText ? .text : nil)
        }
        let result = VoiceEditor.apply(speech.spokenTurns(from: cut), gate: gate)
        if let question = result.question { ask(question) }
        return result
    }

    /// What to say to undo a voice edit.
    var undoPhrase: String {
        judgeMode == .trigger ? "\(triggerWord) " + String(localized: "되돌려") : String(localized: "되돌려")
    }

    private func ask(_ question: CommandQuestion) {
        guard verdicts[question.key] == nil, judgeTasks[question.key] == nil else { return }
        let judge = jevJudge, key = jevKeyOverride ?? jevKey
        judgeTasks[question.key] = Task { [weak self] in
            let answer = await judge.judge(question, key: key)
            guard !Task.isCancelled else { return }
            self?.judged(question, answer)
        }
    }

    private func judged(_ question: CommandQuestion, _ answer: JudgeAnswer) {
        judgeTasks[question.key] = nil
        verdicts[question.key] = answer.verdict
        judgeLog.append((question, answer))
        mirror("")
        if speech.isRecording { turnFinalized("") }
        if completionPending, !waitsForJudge() {
            completionPending = false
            complete("")
        }
    }

    /// Starts every question the finished dictation still needs; true while any is unanswered.
    private func waitsForJudge() -> Bool {
        let full = edited(from: nil)
        let field = edited(from: cutMs)
        if case .pending = enterCommand(in: full.text) { return true }
        return full.question != nil || field.question != nil
    }

    /// A new dictation or a cancel stops waiting: what Jev has not answered yet stays text.
    private func stopJudging() {
        if completionPending {
            unansweredAsText = true
            completionPending = false
            complete("")
        }
        judgeTasks.values.forEach { $0.cancel() }
        judgeTasks = [:]
        verdicts = [:]
        judgeLog = []
        unansweredAsText = false
    }

    func saveJevKey() {
        jevKeyMessage = JevKeychain.save(jevKey) ? String(localized: "Jev 키를 저장했어요.") : String(localized: "Jev 키를 저장하지 못했어요.")
    }

    func loadJevKey() { jevKey = JevKeychain.load() ?? "" }

    private enum EnterCommand {
        case none, said(before: String), pending(before: String), typed
    }

    /// Whether the text ends with the spoken Return. With Jev it counts once Jev calls it a command; until then
    /// it is pending, and the phrase is held back from the field.
    private func enterCommand(in text: String) -> EnterCommand {
        guard let before = spokenEnter?.strip(text) else { return .none }
        guard judgeMode == .jev, !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .said(before: before) }
        let last = speech.spokenTurns(from: nil).last.map(VoiceEditor.questionKey) ?? ""
        let question = CommandQuestion(key: "enter|" + last, textBefore: before, utterance: spokenEnterPhrase,
                                       joint: .ownChunk, effect: "press Return to send the dictated text")
        switch verdicts[question.key] ?? (unansweredAsText ? .text : nil) {
        case .command?: return .said(before: before)
        case .text?: return .typed
        case nil:
            ask(question)
            return .pending(before: before)
        }
    }

    /// The feedback line after a voice edit: what the newest edit did, until more words are typed after it. Kept
    /// longer, "Deleted the last sentence" sat under a transcript that still showed the sentence said after it.
    static func editNote(_ current: String, reported: Int, field: VoiceEditor.Result, undo: String) -> String {
        guard let last = field.outcomes.last else { return current }
        if field.outcomes.count > reported { return describe(last, undo: undo) }
        return field.saidMoreAfterEdit && current == describe(last, undo: undo) ? "" : current
    }

    static func describe(_ outcome: VoiceEditor.Outcome, undo: String) -> String {
        switch outcome {
        case .applied(.deleteLastSentence): String(localized: "마지막 문장을 지웠어요. '\(undo)'라고 말하면 되돌려요.")
        case .applied(.deleteLastWord): String(localized: "마지막 단어를 지웠어요. '\(undo)'라고 말하면 되돌려요.")
        case .applied(.clearAll): String(localized: "받아쓴 글을 모두 지웠어요. '\(undo)'라고 말하면 되돌려요.")
        case .applied(.undo): String(localized: "되돌렸어요.")
        // The mark shows up in the text itself.
        case .applied(.mark): ""
        case .applied(.replace(let old, let new)):
            String(localized: "'\(old)'을(를) '\(new)'(으)로 바꿨어요. '\(undo)'라고 말하면 되돌려요.")
        case .applied(.delete(let old)): String(localized: "'\(old)'을(를) 지웠어요. '\(undo)'라고 말하면 되돌려요.")
        case .nothingToChange(.undo): String(localized: "되돌릴 것이 없어요.")
        case .nothingToChange: String(localized: "고칠 글이 없어요.")
        case .notFound(let old): String(localized: "'\(old)'을(를) 찾지 못해 바꾸지 않았어요.")
        }
    }

    private func withoutEnterCommand(_ text: String) -> String {
        switch enterCommand(in: text) {
        case .said(let before), .pending(let before): withoutWakeStop(before)
        case .none, .typed: withoutWakeStop(text)
        }
    }

    /// The wake phrase said at the end of a dictation finishes it and is not typed. While it is still being said
    /// ("… 헤이") live typing waits for the rest.
    /// Also the last step before text is typed or kept, so punctuation is dropped here, after every command match.
    private func withoutWakeStop(_ text: String) -> String {
        punctuationStyle.apply(withWakeStop(text))
    }

    private func withWakeStop(_ text: String) -> String {
        guard wakeListeningEnabled else { return text }
        let wake = wakeSpoken
        if let rest = wake.strippingSuffix(text) { return rest }
        guard speech.isRecording, let start = wake.partialSuffixStart(text) else { return text }
        return String(text[..<start]).trimmingCharacters(in: .whitespaces)
    }

    /// A command only counts once Soniox has finalized it, so a phrase still being said never stops dictation.
    private func turnFinalized(_: String) {
        let text = edited(from: nil).text
        let wakeStop = wakeListeningEnabled && wakeSpoken.strippingSuffix(text) != nil
        if case .said = enterCommand(in: text) { speech.finish() } else if wakeStop { speech.finish() }
    }

    private func complete(_: String) {
        overlayVisible = true
        if judgeMode == .jev, waitsForJudge() {
            completionPending = true
            return
        }
        let spoken = edited(from: nil).text
        if printsTurnsAndQuits {
            for turn in speech.spokenTurns(from: nil) {
                print("\(turn.pauseBeforeMs.map(String.init) ?? "-")\t\(turn.text.trimmingCharacters(in: .whitespaces))")
            }
            for (question, answer) in judgeLog {
                let probability = answer.commandProbability.map { String(format: "%.2f", $0) } ?? "-"
                print("jev\t\(answer.verdict)\t\(probability)\t\(answer.milliseconds)ms\t\(answer.inputTokens)tok\t\(question.utterance)\t\(answer.failure ?? "")")
            }
            print("=>\t\(punctuationStyle.apply(spoken))")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        var command: String?
        if case .said(let before) = enterCommand(in: spoken) { command = before }
        let text = withoutWakeStop(command ?? spoken)
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !empty {
            history.insert(DictationRecord(text: text), at: 0)
            if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        }
        // A key or click while the last words were being finalized counts like one during recording.
        if let live, let acted = live.userActedAt { moveOn(at: acted) }
        let movedOn = cutMs != nil
        let field = edited(from: cutMs).text
        let rest = withoutEnterCommand(field)
        // The spoken Enter alone, after the user moved the caret, still goes to the field they settled in.
        if live == nil, awaitingTarget, command != nil || !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            case .applied where empty: feedback = String(localized: "인식된 음성이 없어 입력하지 않았어요.")
            case .applied: routine(String(localized: "입력 칸에 받아쓰기를 입력했어요."))
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
        liveTargetName = nil
        liveTargetIcon = nil
        awaitingTarget = false
        cutMs = nil
        reportedEdits = 0
        feedback = ""
        guard autoInsert else { return }
        guard accessibilityGranted else {
            feedback = String(localized: "'\(ControlPermissionPane.current.title)' 권한이 없어 결과를 보관해요.")
            return
        }
        // Started from our own settings window: give focus back to the app the user was typing in.
        if NSApp.isActive { NSApp.deactivate() }
        if acquireLiveTarget() {
            routine(String(localized: "선택한 칸에 실시간으로 입력해요."))
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
        let app = NSRunningApplication(processIdentifier: target.pid)
        liveTargetName = app?.localizedName
        liveTargetIcon = app?.icon
        awaitingTarget = false
        return true
    }

    func toggleRecording() {
        overlayVisible = true
        if isRecording { speech.finish() }
        else if !isBusy {
            stopJudging()
            startLiveTypingIfAdmitted()
            speech.start()
        }
    }
    func handle(_ request: DictationRequest) {
        switch request.effect(isRecording: isRecording, isBusy: isBusy) {
        case .start, .finish: toggleRecording()
        case .none: overlayVisible = true
        }
    }
    func cancel() {
        guard isBusy || completionPending else { return }
        completionPending = false
        judgeTasks.values.forEach { $0.cancel() }
        judgeTasks = [:]
        let hadTyped = !(live?.typed.isEmpty ?? true)
        let removed = hadTyped && live?.sync("") == .applied
        live = nil
        liveTargetName = nil
        liveTargetIcon = nil
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
        stopJudging()
        startLiveTypingIfAdmitted()
        speech.start(audioFile: url)
    }

    /// Scripted synthetic transcript for `--demo <en|ko>`: drives the overlay and its history with made-up
    /// sentences. No microphone, network, Keychain, or other app's text field is touched.
    enum DemoLocale: String, Sendable {
        case en, ko

        var history: [String] {
            switch self {
            case .en: ["Checked the build logs and verified all unit tests pass on Apple Silicon."]
            case .ko: ["애플 실리콘에서 빌드 로그와 단위 테스트 통과를 모두 확인했습니다."]
            }
        }

        var targetName: String {
            switch self {
            case .en: "Notes"
            case .ko: "메모"
            }
        }

        var animationSteps: [String] {
            switch self {
            case .en:
                [
                    "Please",
                    "Please tidy up",
                    "Please tidy up the meeting",
                    "Please tidy up the meeting notes",
                    "Please tidy up the meeting notes and share",
                    "Please tidy up the meeting notes and share the draft",
                    "Please tidy up the meeting notes and share the draft with the team",
                    "Please tidy up the meeting notes and share the draft with the team by this afternoon.",
                ]
            case .ko:
                [
                    "회의록",
                    "회의록 초안을",
                    "회의록 초안을 오늘",
                    "회의록 초안을 오늘 오후까지",
                    "회의록 초안을 오늘 오후까지 정리해서",
                    "회의록 초안을 오늘 오후까지 정리해서 팀에",
                    "회의록 초안을 오늘 오후까지 정리해서 팀에 공유해",
                    "회의록 초안을 오늘 오후까지 정리해서 팀에 공유해 주세요.",
                ]
            }
        }

        var steps: [String] {
            switch self {
            case .en:
                [
                    "Please tidy up",
                    "Please tidy up the meeting notes",
                    "Please tidy up the meeting notes and share the draft",
                    "Please tidy up the meeting notes and share the draft with the team by this afternoon.",
                ]
            case .ko:
                [
                    "회의록 초안을",
                    "회의록 초안을 오늘 오후까지",
                    "회의록 초안을 오늘 오후까지 정리해서",
                    "회의록 초안을 오늘 오후까지 정리해서 팀에 공유해 주세요.",
                ]
            }
        }
    }

    func seedDemoHistory(_ lines: [String]) {
        history = lines.map { DictationRecord(text: $0) }
    }

    func configureDemoTarget(name: String?, icon: NSImage?) {
        liveTargetName = name
        liveTargetIcon = icon
    }

    func setRoutineFeedback(_ text: String) {
        routine(text)
    }

    /// Synthetic state for `--demo-capture`. Only in-memory values change: every setting that persists to
    /// UserDefaults is left alone, because the capture process shares the installed app's defaults domain.
    func configureForDemoCapture() {
        let microphone = AudioInputDevice(uid: "demo-mic", name: "MacBook Pro Microphone")
        apiKey = "soniox-demo-synthetic-api-key-0123456789"
        jevKey = "jev-demo-synthetic-api-key-0123456789"
        accessibilityGranted = true
        microphoneAccessOverride = .granted
        defaultInputDevice = microphone
        inputDevices = [microphone]
        autoInsert = true
        feedback = ""
        seedDemoHistory([])
        configureDemoTarget(name: nil, icon: nil)
    }

    @discardableResult
    func runDemo(_ locale: DemoLocale, stepInterval: Duration = .milliseconds(220),
                 holdBeforeFinish: Duration = .milliseconds(700)) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        overlayVisible = true
        stopJudging()
        return speech.runDemo(steps: locale.steps, stepInterval: stepInterval, holdBeforeFinish: holdBeforeFinish)
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
