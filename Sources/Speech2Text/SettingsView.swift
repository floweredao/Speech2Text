import AVFoundation
import AppKit
import DictationSpeech
import SwiftUI

/// The privacy pane that grants control of other apps (`AXIsProcessTrusted`). macOS 27 renamed
/// it from Accessibility to Device Control and Data Management. See DESIGN.md, "설정 창".
enum ControlPermissionPane: Equatable {
    case deviceControl
    case accessibility

    init(osMajorVersion: Int) { self = osMajorVersion >= 27 ? .deviceControl : .accessibility }

    static var current: Self { Self(osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) }

    var title: String {
        switch self {
        case .deviceControl: String(localized: "기기 제어 및 데이터 관리")
        case .accessibility: String(localized: "손쉬운 사용")
        }
    }

    var guidance: String {
        switch self {
        case .deviceControl:
            String(localized: "시스템 설정 › 개인정보 보호 및 보안 › Device Control and Data Management에서 Speech2Text를 켜세요. macOS 26 이하의 '손쉬운 사용'과 같은 권한이에요.")
        case .accessibility:
            String(localized: "시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 Speech2Text를 켜세요. macOS 27부터는 'Device Control and Data Management'라는 이름이에요.")
        }
    }
}

extension NSColor {
    /// Warning text: system orange is too light for small text on the light grouped background, so light
    /// appearances use a darker orange (at least 4.5:1). Icons keep `Color.orange`.
    static let warningText = NSColor(name: "warningText") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemOrange : NSColor(srgbRed: 0.64, green: 0.28, blue: 0, alpha: 1)
    }
}

extension Color {
    static let warningText = Color(nsColor: .warningText)
}

enum MicrophoneAccess: Equatable {
    case granted, notDetermined, denied

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notDetermined
        case .denied, .restricted: self = .denied
        @unknown default: self = .denied
        }
    }
}

/// Prerequisites for dictating into another app. Asking is never automatic.
struct SetupReadiness: Equatable {
    let hasKey: Bool
    let microphone: MicrophoneAccess
    let controlGranted: Bool

    /// Not-yet-asked microphone access is not missing: macOS asks on first recording.
    var missingCount: Int {
        [!hasKey, microphone == .denied, !controlGranted].filter { $0 }.count
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    /// `State` struct instead of the `@State` macro: the CLT toolchain ships no SwiftUIMacros plugin.
    private let microphoneState = State(initialValue: MicrophoneAccess(AVCaptureDevice.authorizationStatus(for: .audio)))
    private var microphone: MicrophoneAccess { model.microphoneAccessOverride ?? microphoneState.wrappedValue }
    private let confirmDeleteState = State(initialValue: false)
    private let recorderState = State(initialValue: ShortcutRecorder())
    private var recorder: ShortcutRecorder { recorderState.wrappedValue }
    private let newTermState = State(initialValue: "")
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Rows a switch or picker reveals slide in with the overlay's layout curve; Reduce Motion shows them at once.
    private var rowMotion: Animation? { reduceMotion ? nil : OverlayMotion.layout }

    private let pane = ControlPermissionPane.current
    private var state: DictationDisplayState { DictationDisplayState(model: model) }
    private var keyBusy: Bool { model.speech.keyActivity != .idle }
    private var keyActivityText: String? {
        switch model.speech.keyActivity {
        case .idle: nil
        case .saving: String(localized: "Keychain에 저장하는 중…")
        case .loading: String(localized: "Keychain에서 불러오는 중…")
        case .deleting: String(localized: "Keychain에서 지우는 중…")
        }
    }
    private var hasKey: Bool { !model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var readiness: SetupReadiness {
        SetupReadiness(hasKey: hasKey, microphone: microphone, controlGranted: model.accessibilityGranted)
    }

    var body: some View {
        Form {
            statusSection
            setupSection
            inputSection
            vocabularySection
            shortcutSection
            voiceStartSection
            experimentalSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, idealWidth: 480, maxWidth: 640, minHeight: 420, idealHeight: 540)
        .onAppear(perform: refreshPermissions)
        .onDisappear { recorder.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            recorder.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            HStack(alignment: .top, spacing: Spacing.m) {
                Image(systemName: statusSymbol)
                    .font(.title2)
                    .foregroundStyle(statusTint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(state.phase == .error ? state.title : model.status)
                        .font(.headline)
                        .accessibilityIdentifier("settings-status")
                    if state.phase == .error {
                        Text(model.status)
                            .font(.callout)
                            .foregroundStyle(Color.warningText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings-error")
                    }
                    if !model.feedback.isEmpty {
                        Text(model.feedback)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings-feedback")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: Spacing.s) {
                    Button(recordButtonTitle, systemImage: model.isRecording ? "stop.fill" : "mic.fill") {
                        model.toggleRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy && !model.isRecording)
                    .accessibilityIdentifier("settings-record")
                    if model.isBusy {
                        Button("취소", role: .cancel) { model.cancel() }
                            .accessibilityIdentifier("settings-cancel")
                    }
                }
                .fixedSize()
            }
            if readiness.missingCount > 0 {
                Label {
                    Text("아래 준비 항목 \(readiness.missingCount)개를 확인해 주세요.")
                        .foregroundStyle(Color.warningText)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                    .font(.callout)
                    .accessibilityIdentifier("settings-readiness")
            }
        }
    }

    private var setupSection: some View {
        Section("준비") {
            SecureField("Soniox API 키", text: $model.apiKey, prompt: Text("키를 붙여넣으세요"))
                .textContentType(.password)
                .disabled(keyBusy)
                .accessibilityIdentifier("settings-api-key")
            HStack {
                Button("저장") { model.saveKey() }
                    .disabled(!hasKey || keyBusy)
                    .help("이 앱 전용 Keychain 항목에 저장해요.")
                    .accessibilityIdentifier("settings-save-key")
                Button("불러오기") { model.loadKey() }
                    .disabled(keyBusy)
                    .help("이 앱의 Keychain 항목에서 불러와요.")
                    .accessibilityIdentifier("settings-load-key")
                Spacer()
                Button("저장된 키 삭제", role: .destructive) { confirmDeleteState.wrappedValue = true }
                    .disabled(keyBusy)
                    .help("이 Mac의 Keychain에서 Soniox API 키를 지워요.")
                    .accessibilityIdentifier("settings-delete-key")
            }
            .confirmationDialog("저장된 API 키를 지울까요?", isPresented: confirmDeleteState.projectedValue) {
                Button("삭제", role: .destructive) { model.deleteKey() }
                    .accessibilityIdentifier("settings-confirm-delete-key")
            } message: {
                Text("다시 받아쓰려면 키를 새로 붙여넣고 저장해야 해요.")
            }
            if let activity = keyActivityText {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text(activity)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings-key-activity")
            } else if !model.speech.keyMessage.isEmpty {
                Text(model.speech.keyMessage)
                    .font(.caption)
                    .foregroundStyle(model.speech.keyFailed ? Color.warningText : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-key-message")
            }
            if !hasKey {
                Text("키를 저장해야 받아쓰기를 시작할 수 있어요.")
                    .font(.caption)
                    .foregroundStyle(Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-key-status")
            }

            LabeledContent {
                // Longer English labels move the buttons under the badge instead of clipping at 440 pt.
                fitting {
                    statusBadge(microphoneBadge, granted: microphone == .granted)
                        .accessibilityIdentifier("settings-microphone-status")
                    switch microphone {
                    case .notDetermined:
                        Button("허용 요청") {
                            Task {
                                _ = await AVCaptureDevice.requestAccess(for: .audio)
                                refreshPermissions()
                            }
                        }
                        .accessibilityIdentifier("settings-request-microphone")
                    case .denied:
                        Button("시스템 설정 열기") { openPrivacyPane("Privacy_Microphone") }
                            .accessibilityIdentifier("settings-open-microphone")
                    case .granted:
                        EmptyView()
                    }
                }
            } label: {
                Text("마이크")
                Text("녹음하는 동안에만 Soniox로 보내요.")
            }

            Picker(selection: $model.inputDeviceUID) {
                Text(defaultDeviceLabel).tag(String?.none)
                ForEach(model.inputDevices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
                if let uid = model.inputDeviceUID, !model.inputDevices.contains(where: { $0.uid == uid }) {
                    Text("연결 안 된 마이크").tag(Optional(uid))
                }
            } label: {
                Text("사용할 마이크")
            }
            .accessibilityIdentifier("settings-input-device")

            LabeledContent {
                fitting {
                    statusBadge(model.accessibilityGranted ? String(localized: "허용됨") : String(localized: "필요함"), granted: model.accessibilityGranted)
                        .accessibilityIdentifier("settings-accessibility-status")
                    if !model.accessibilityGranted {
                        Button("허용 요청") { model.requestAccessibility() }
                            .accessibilityIdentifier("settings-request-accessibility")
                        Button("시스템 설정 열기") { openPrivacyPane("Privacy_Accessibility") }
                            .accessibilityIdentifier("settings-open-accessibility")
                    }
                }
            } label: {
                Text(pane.title)
                if !model.accessibilityGranted {
                    Text(pane.guidance)
                }
            }
        }
    }

    private var inputSection: some View {
        Section("입력") {
            Toggle(isOn: $model.autoInsert) {
                Text("말하는 동안 바로 입력")
                Text("선택한 칸에 실시간으로 쓰고, 인식이 고쳐지면 바로 고쳐요.")
            }
            .accessibilityIdentifier("settings-auto-insert")
            Toggle(isOn: $model.spokenEnterEnabled.animation(rowMotion)) {
                Text("말로 엔터 누르기")
                if model.commandJudge == .jev {
                    Text("끝에 ‘\(model.spokenEnterPhrase)’라고 말하면 Jev가 명령이라고 판단할 때 엔터를 눌러요.")
                } else {
                    Text("끝에 ‘\(model.triggerWord) \(model.spokenEnterPhrase)’라고 말하고 잠깐 멈추면 엔터를 눌러요.")
                }
            }
            .accessibilityIdentifier("settings-spoken-enter")
            if model.spokenEnterEnabled {
                TextField("명령어", text: $model.spokenEnterPhrase, prompt: Text("엔터 보내기"))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("settings-spoken-enter-phrase")
            }
            Picker(selection: $model.commandJudge.animation(rowMotion)) {
                Text("트리거 단어").tag(CommandJudgeMode.trigger)
                Text("Jev가 판단").tag(CommandJudgeMode.jev)
                Text("끄기").tag(CommandJudgeMode.off)
            } label: {
                Text("말로 고치기")
                switch model.commandJudge {
                case .trigger:
                    Text("‘\(model.triggerWord) 지워’, ‘\(model.triggerWord) 되돌려’, ‘\(model.triggerWord) A를 B로 바꿔’처럼 말하면 고쳐요.")
                case .jev:
                    Text("‘지워’, ‘되돌려’, ‘A를 B로 바꿔’를 따로 말하면 Jev가 명령인지 글인지 판단해요. 애매하면 글로 써요. 그 말과 앞 글 일부를 TypeSafe로 보내요.")
                case .off:
                    Text("명령을 듣지 않고 모두 글로 써요.")
                }
            }
            .accessibilityIdentifier("settings-command-judge")
            if model.commandJudge == .jev {
                SecureField("Jev API 키", text: $model.jevKey, prompt: Text("키를 붙여넣으세요"))
                    .textContentType(.password)
                    .accessibilityIdentifier("settings-jev-key")
                HStack {
                    Button("저장") { model.saveJevKey() }
                        .disabled(model.jevKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("이 앱 전용 Keychain 항목에 저장해요.")
                        .accessibilityIdentifier("settings-save-jev-key")
                    Spacer()
                    if !model.jevKeyMessage.isEmpty {
                        Text(model.jevKeyMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.jevKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Jev 키가 없으면 명령처럼 들린 말도 모두 글로 써요.")
                        .font(.caption)
                        .foregroundStyle(Color.warningText)
                }
            }
            if model.commandJudge == .trigger || (model.commandJudge == .off && model.spokenEnterEnabled) {
                // LabeledContent, not the field's own label: a grouped form centers a two-line field label.
                LabeledContent {
                    TextField("트리거 단어", text: $model.triggerWord, prompt: Text(AppModel.defaultTriggerWord))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("settings-trigger-word")
                } label: {
                    Text("트리거 단어")
                    Text("명령 앞에 붙이는 말이에요. 없이 말한 ‘지워’는 그대로 글로 써요.")
                }
                if model.trigger.isEmpty {
                    Text("트리거 단어가 비어 있으면 말로 고치기와 엔터가 먹지 않아요.")
                        .font(.caption)
                        .foregroundStyle(Color.warningText)
                }
            }
            Picker(selection: $model.punctuationStyle) {
                Text("그대로").tag(PunctuationStyle.asIs)
                Text("쉼표 빼기").tag(PunctuationStyle.noCommas)
                Text("모두 빼기").tag(PunctuationStyle.none)
            } label: {
                Text("문장부호")
                switch model.punctuationStyle {
                case .asIs: Text("인식된 문장부호를 그대로 써요.")
                case .noCommas: Text("쉼표만 빼고 마침표·물음표·느낌표는 남겨요. 1,000 같은 숫자 속 쉼표는 남겨요.")
                case .none: Text("쉼표와 마침표·물음표·느낌표를 모두 빼요. 3.14 같은 숫자는 그대로예요.")
                }
            }
            .accessibilityIdentifier("settings-punctuation")
            Picker(selection: $model.silenceStopSeconds) {
                timeoutChoices
            } label: {
                Text("말이 없으면 받아쓰기 마치기")
                Text("새로 인식된 말이 없으면 들은 데까지 마쳐요.")
            }
            .accessibilityIdentifier("settings-silence-stop")
            Picker(selection: $model.overlayAutoCloseSeconds) {
                timeoutChoices
            } label: {
                Text("화면 위쪽 표시 자동으로 닫기")
                Text("받아쓰기 없이 그대로면 닫아요. 포인터가 위에 있으면 기다려요.")
            }
            .accessibilityIdentifier("settings-overlay-auto-close")
            LabeledContent("화면 위쪽 표시") {
                Button("열기") { model.showOverlay() }
                    .accessibilityIdentifier("settings-show-overlay")
            }
        }
    }

    private var voiceStartSection: some View {
        Section {
            Toggle(isOn: $model.wakeListeningEnabled.animation(rowMotion)) {
                Text("호출어로 시작·끝내기")
                Text("‘\(model.wakePhrase)’라고 말하면 받아쓰기를 시작하고, 받아쓰다 끝에 다시 말하면 마쳐요.")
            }
            .accessibilityIdentifier("settings-wake-word")
            if model.wakeListeningEnabled {
                LabeledContent {
                    TextField("호출어", text: $model.wakePhrase, prompt: Text(AppModel.defaultWakePhrase))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("settings-wake-phrase")
                } label: {
                    Text("호출어")
                    Text("영어 글자로 적어요.")
                }
                Picker(selection: $model.wakeSensitivity) {
                    Text("낮음").tag(WakeSensitivity.low)
                    Text("보통").tag(WakeSensitivity.standard)
                    Text("높음").tag(WakeSensitivity.high)
                } label: {
                    Text("민감도")
                    Text("높일수록 작게 말해도 알아듣지만, 비슷한 말에도 켜질 수 있어요.")
                }
                .accessibilityIdentifier("settings-wake-sensitivity")
                if let problem = model.wakeProblem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Color.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-wake-problem")
                }
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("음성 제어")
                Text("1. 단축어 앱에서 새 단축어를 만들고 Speech2Text의 '받아쓰기 시작' 동작을 넣어요.\n2. 시스템 설정 › 손쉬운 사용 › 음성 제어 › 명령에서 +를 눌러 말할 문구를 적고, 동작은 '단축어 실행'으로 골라 그 단축어를 지정해요.\n3. '받아쓰기 끝내기'도 같은 방법으로 만들어요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("음성 제어는 켜져 있는 동안 계속 듣고, 말한 내용을 직접 입력하기도 해요. 글이 두 번 들어가면 음성 제어를 명령 모드로 바꿔 주세요.")
                    .font(.caption)
                    .foregroundStyle(Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-voice-control")
            Button("단축어 앱 열기") {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                    NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            .accessibilityIdentifier("settings-open-shortcuts")
        } header: {
            Text("음성으로 시작")
        } footer: {
            Group {
                if model.wakeListeningEnabled {
                    Text("호출어를 듣는 동안 마이크가 켜져 있어요(메뉴 막대에 주황색 점). 들은 소리는 이 맥 안에서만 처리하고 저장하거나 보내지 않아요. 블루투스 이어폰 마이크로 들으면 그동안 이어폰 음질이 낮아질 수 있어요.")
                } else {
                    Text("이 앱은 받아쓰는 동안에만 마이크를 켜요.")
                }
            }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var experimentalSection: some View {
        Section("실험적 기능") {
            Picker(selection: $model.translationTarget) {
                ForEach(AppModel.translationChoices, id: \.self) { code in
                    Text(Self.translationLabel(code)).tag(code)
                }
            } label: {
                Text("실시간 번역")
                Text("말한 내용을 고른 언어로 번역해 입력해요. 말로 고치기·엔터는 번역된 글 기준이라 잘 안 될 수 있어요.")
            }
            .accessibilityIdentifier("settings-translation")
            Toggle(isOn: $model.marksUncertainWords) {
                Text("확실하지 않은 단어 표시")
                Text("잘못 들었을 수 있는 단어에 점선 밑줄을 칠해요.")
            }
            .accessibilityIdentifier("settings-uncertain-words")
        }
    }

    static func translationLabel(_ code: String?) -> String {
        switch code {
        case "en": String(localized: "영어로")
        case "ko": String(localized: "한국어로")
        case "ja": String(localized: "일본어로")
        case "zh": String(localized: "중국어로")
        default: String(localized: "끄기")
        }
    }

    private var timeoutChoices: some View {
        ForEach(AppModel.timeoutChoices, id: \.self) { seconds in
            Text(Self.timeoutLabel(seconds)).tag(seconds)
        }
    }

    static func timeoutLabel(_ seconds: Int) -> String {
        if seconds <= 0 { return String(localized: "끄기") }
        if seconds < 60 { return String(localized: "\(seconds)초") }
        return String(localized: "\(seconds / 60)분")
    }

    private var vocabularySection: some View {
        Section {
            if !model.dictionary.isEmpty {
                FlowLayout(spacing: Spacing.s) {
                    ForEach(model.dictionary, id: \.self) { termChip($0) }
                }
                .padding(.vertical, Spacing.xxs)
                .accessibilityIdentifier("settings-dictionary")
            }
            TextField("단어 추가", text: newTermState.projectedValue, prompt: Text("입력 후 Return"))
                .multilineTextAlignment(.trailing)
                .onSubmit {
                    model.addDictionaryTerms(newTermState.wrappedValue)
                    newTermState.wrappedValue = ""
                }
                .accessibilityIdentifier("settings-dictionary-add")
        } header: {
            Text("사전")
        } footer: {
            Text("자주 쓰는 단어를 적어 두면 더 정확히 받아써요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func termChip(_ term: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(term)
                .lineLimit(1)
            Button("'\(term)' 지우기", systemImage: "xmark") { model.removeDictionaryTerm(term) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        // The remove button carries its own few points of padding, so the trailing side needs less.
        .padding(.leading, Spacing.s)
        .padding(.trailing, Spacing.xs)
        .padding(.vertical, Spacing.xs)
        .background(.quaternary, in: Capsule())
    }

    private var shortcutSection: some View {
        Section("단축키") {
            ForEach(ShortcutAction.allCases, id: \.self) { action in
                shortcutRow(action)
            }
            Text("기록할 때 키 대신 마우스 옆 버튼이나 가운데 버튼을 눌러도 돼요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-shortcut-mouse-hint")
            if !model.shortcutNote.isEmpty {
                Text(model.shortcutNote)
                    .font(.caption)
                    .foregroundStyle(Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-shortcut-note")
            }
            if !model.shortcutProblem.isEmpty {
                Text(model.shortcutProblem)
                    .font(.caption)
                    .foregroundStyle(Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-shortcut-problem")
            }
            if model.shortcuts.usesModifierOnlyTrigger && !model.accessibilityGranted {
                Text("수정 키만 누르는 단축키는 '\(pane.title)' 권한이 있어야 동작해요.")
                    .font(.caption)
                    .foregroundStyle(Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-shortcut-permission")
            }
            if model.shortcuts != .standard {
                Button("기본값으로 되돌리기") {
                    recorder.cancel()
                    model.shortcutNote = ""
                    model.shortcuts = .standard
                }
                .accessibilityIdentifier("settings-shortcut-reset")
            }
        }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let recording = model.capturingShortcut == action
        let shortcut = model.shortcuts[action]
        return LabeledContent {
            HStack(spacing: Spacing.s) {
                Button {
                    if recording { recorder.cancel() } else { recorder.begin(action, model: model) }
                } label: {
                    Text(recording ? (model.shortcutPreview.isEmpty ? String(localized: "키를 누르세요…") : model.shortcutPreview)
                                   : (shortcut?.label ?? String(localized: "없음")))
                        .frame(minWidth: 120)
                }
                .buttonStyle(.bordered)
                .tint(recording ? .accentColor : nil)
                .help(recording ? String(localized: "누르면 기록을 취소해요.") : String(localized: "눌러서 새 단축키를 기록해요."))
                .accessibilityLabel(recording ? String(localized: "단축키 기록 중") : (shortcut?.spokenLabel ?? String(localized: "단축키 없음")))
                .accessibilityHint("눌러서 새 단축키를 기록해요.")
                .accessibilityIdentifier("settings-shortcut-\(action.rawValue)")
                // The clear button keeps its place when there is nothing to clear, so every row's shortcut
                // button lines up with the rows above and below it.
                let clearable = shortcut != nil && !recording
                Button("단축키 끄기", systemImage: "xmark.circle.fill") { model.shortcuts[action] = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("이 단축키를 꺼요.")
                    .opacity(clearable ? 1 : 0)
                    .disabled(!clearable)
                    .accessibilityHidden(!clearable)
                    .accessibilityIdentifier("settings-shortcut-clear-\(action.rawValue)")
            }
        } label: {
            Text(action.title)
            if recording {
                Text("누르면 기록돼요. 두세 번 연달아 누르면 여러 번 누르기로, 양쪽 ⇧처럼 수정 키만 눌러도 돼요. Esc는 취소.")
            }
        }
    }

    // MARK: Helpers

    private struct FlowLayout: Layout {
        var spacing: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            arrange(subviews, width: proposal.width ?? .infinity).size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let frames = arrange(subviews, width: bounds.width).frames
            for (subview, frame) in zip(subviews, frames) {
                subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                              proposal: ProposedViewSize(frame.size))
            }
        }

        private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
            var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
            for subview in subviews {
                let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                if x > 0, x + size.width > width {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
                x += size.width + spacing
                widest = max(widest, x - spacing)
                rowHeight = max(rowHeight, size.height)
            }
            return (frames, CGSize(width: widest, height: y + rowHeight))
        }
    }

    /// One row when it fits, otherwise the badge above its buttons.
    private func fitting(@ViewBuilder _ content: () -> some View) -> some View {
        let content = content()
        return ViewThatFits(in: .horizontal) {
            HStack { content }
            VStack(alignment: .trailing, spacing: Spacing.s) { content }
        }
    }

    /// The icon carries the color; the words stay readable text (green and orange are too light for text).
    private func statusBadge(_ text: String, granted: Bool) -> some View {
        Label {
            Text(text).foregroundStyle(granted ? Color.primary : Color.warningText)
        } icon: {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
        }
        .fixedSize()
    }

    private var defaultDeviceLabel: String {
        model.defaultInputDevice.map { String(localized: "시스템 기본값 (\($0.name))") } ?? String(localized: "시스템 기본값")
    }

    private var microphoneBadge: String {
        switch microphone {
        case .granted: String(localized: "허용됨")
        case .notDetermined: String(localized: "아직 묻지 않음")
        case .denied: String(localized: "거부됨")
        }
    }

    private var recordButtonTitle: String {
        if model.isRecording { return String(localized: "마무리") }
        if model.isBusy { return state.title }
        return String(localized: "받아쓰기 시작")
    }

    private var statusSymbol: String {
        switch state.phase {
        case .recording: "record.circle"
        case .connecting, .finalizing: "hourglass"
        case .error: "exclamationmark.triangle.fill"
        default: readiness.missingCount > 0 ? "exclamationmark.circle" : "waveform.circle"
        }
    }

    private var statusTint: Color {
        switch state.phase {
        case .recording: .red
        case .error: .orange
        default: readiness.missingCount > 0 ? .orange : .accentColor
        }
    }

    private func refreshPermissions() {
        guard model.microphoneAccessOverride == nil else { return }
        model.accessibilityGranted = AXIsProcessTrusted()
        microphoneState.wrappedValue = MicrophoneAccess(AVCaptureDevice.authorizationStatus(for: .audio))
        model.refreshInputDevices()
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
