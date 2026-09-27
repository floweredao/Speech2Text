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
    private var microphone: MicrophoneAccess { microphoneState.wrappedValue }
    private let confirmDeleteState = State(initialValue: false)
    private let recorderState = State(initialValue: ShortcutRecorder())
    private var recorder: ShortcutRecorder { recorderState.wrappedValue }

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
            shortcutSection
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
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.title2)
                    .foregroundStyle(statusTint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.phase == .error ? state.title : model.status)
                        .font(.headline)
                        .accessibilityIdentifier("settings-status")
                    if state.phase == .error {
                        Text(model.status)
                            .font(.callout)
                            .foregroundStyle(.orange)
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
                VStack(alignment: .trailing, spacing: 6) {
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
                Label("아래 준비 항목 \(readiness.missingCount)개를 확인해 주세요.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
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
                    .help("이 앱 전용 Keychain 항목에 저장합니다.")
                    .accessibilityIdentifier("settings-save-key")
                Button("불러오기") { model.loadKey() }
                    .disabled(keyBusy)
                    .help("이 앱의 Keychain 항목에서 불러옵니다.")
                    .accessibilityIdentifier("settings-load-key")
                Spacer()
                Button("저장된 키 삭제", role: .destructive) { confirmDeleteState.wrappedValue = true }
                    .disabled(keyBusy)
                    .help("이 Mac의 Keychain에서 Soniox API 키를 지웁니다.")
                    .accessibilityIdentifier("settings-delete-key")
            }
            .confirmationDialog("저장된 API 키를 지울까요?", isPresented: confirmDeleteState.projectedValue) {
                Button("삭제", role: .destructive) { model.deleteKey() }
                    .accessibilityIdentifier("settings-confirm-delete-key")
            } message: {
                Text("다시 받아쓰려면 키를 새로 붙여넣고 저장해야 해요.")
            }
            if let activity = keyActivityText {
                HStack(spacing: 6) {
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
                    .foregroundStyle(model.speech.keyFailed ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-key-message")
            }
            if !hasKey {
                Text("키가 없으면 받아쓰기를 시작할 수 없어요. 저장하면 이 앱의 Keychain에 보관돼 다음 실행에도 남아요.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-key-status")
            }

            LabeledContent {
                HStack {
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
                Text("받아쓰는 동안에만 Soniox로 음성을 보내요.")
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
                Text("선택한 마이크가 없으면 받아쓰기를 시작하지 않고 알려 드려요.")
            }
            .accessibilityIdentifier("settings-input-device")

            LabeledContent {
                HStack {
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
                Text("시작할 때 선택한 입력 칸에 실시간으로 쓰고, 인식이 고쳐지면 그 부분도 바로 고쳐요. 칸이 바뀌면 멈추고 결과를 보관해요.")
            }
            .accessibilityIdentifier("settings-auto-insert")
            LabeledContent("화면 위쪽 표시") {
                Button("열기") { model.overlayVisible = true }
                    .accessibilityIdentifier("settings-show-overlay")
            }
        }
    }

    private var shortcutSection: some View {
        Section("단축키") {
            ForEach(ShortcutAction.allCases, id: \.self) { action in
                shortcutRow(action)
            }
            if !model.shortcutNote.isEmpty {
                Text(model.shortcutNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-shortcut-note")
            }
            if !model.shortcutProblem.isEmpty {
                Text(model.shortcutProblem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-shortcut-problem")
            }
            if model.shortcuts.usesModifierOnlyTrigger && !model.accessibilityGranted {
                Text("수정 키만 누르는 단축키는 '\(pane.title)' 권한이 있어야 동작해요.")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
            HStack(spacing: 6) {
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
                if shortcut != nil && !recording {
                    Button("단축키 끄기", systemImage: "xmark.circle.fill") { model.shortcuts[action] = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("이 단축키를 꺼요.")
                        .accessibilityIdentifier("settings-shortcut-clear-\(action.rawValue)")
                }
            }
        } label: {
            Text(action.title)
            if recording {
                Text("누르면 기록돼요. 두세 번 연달아 누르면 여러 번 누르기로, 양쪽 ⇧처럼 수정 키만 눌러도 돼요. Esc는 취소.")
            }
        }
    }

    // MARK: Helpers

    private func statusBadge(_ text: String, granted: Bool) -> some View {
        Label(text, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(granted ? Color.green : Color.orange)
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
