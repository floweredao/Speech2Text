import AVFoundation
import AppKit
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
        case .deviceControl: "기기 제어 및 데이터 관리"
        case .accessibility: "손쉬운 사용"
        }
    }

    var guidance: String {
        switch self {
        case .deviceControl:
            "시스템 설정 › 개인정보 보호 및 보안 › Device Control and Data Management에서 Speech2Text를 켜세요. macOS 26 이하의 '손쉬운 사용'과 같은 권한이에요."
        case .accessibility:
            "시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 Speech2Text를 켜세요. macOS 27부터는 'Device Control and Data Management'라는 이름이에요."
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

    private let pane = ControlPermissionPane.current
    private var state: DictationDisplayState { DictationDisplayState(model: model) }
    private var hasKey: Bool { !model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var readiness: SetupReadiness {
        SetupReadiness(hasKey: hasKey, microphone: microphone, controlGranted: model.accessibilityGranted)
    }

    var body: some View {
        Form {
            statusSection
            setupSection
            inputSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, idealWidth: 480, maxWidth: 640, minHeight: 420, idealHeight: 540)
        .onAppear(perform: refreshPermissions)
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
                .accessibilityIdentifier("settings-api-key")
            HStack {
                Button("저장") { model.saveKey() }
                    .disabled(!hasKey)
                    .help("이 앱 전용 Keychain 항목에 저장합니다.")
                    .accessibilityIdentifier("settings-save-key")
                Button("불러오기") { model.loadKey() }
                    .help("이 앱의 Keychain 항목에서 불러옵니다.")
                    .accessibilityIdentifier("settings-load-key")
                Spacer(minLength: 8)
                Button("Speech-to-action에서 가져오기") { model.importSourceKey() }
                    .help("Speech-to-action이 저장한 Soniox 키를 이번 한 번만 입력 칸에 넣습니다. 계속 쓰려면 저장하세요.")
                    .accessibilityIdentifier("settings-import-key")
            }
            if !hasKey {
                Text("키가 없으면 받아쓰기를 시작할 수 없어요. 가져온 키는 저장해야 다음 실행에도 남아요.")
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
                Text("말하는 동안에만 Soniox로 음성을 보내요.")
            }

            LabeledContent {
                HStack {
                    statusBadge(model.accessibilityGranted ? "허용됨" : "필요함", granted: model.accessibilityGranted)
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
                Text(pane.guidance)
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
            LabeledContent("받아쓰기 시작 / 마무리") {
                Text("⌃⌥D").font(.body.monospaced()).accessibilityLabel("Control Option D")
            }
            LabeledContent("마지막 결과 붙여넣기") {
                Text("⌃⌥V").font(.body.monospaced()).accessibilityLabel("Control Option V")
            }
            LabeledContent("화면 위쪽 표시") {
                Button("열기") { model.overlayVisible = true }
                    .accessibilityIdentifier("settings-show-overlay")
            }
        }
    }

    // MARK: Helpers

    private func statusBadge(_ text: String, granted: Bool) -> some View {
        Label(text, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(granted ? Color.green : Color.orange)
            .fixedSize()
    }

    private var microphoneBadge: String {
        switch microphone {
        case .granted: "허용됨"
        case .notDetermined: "아직 묻지 않음"
        case .denied: "거부됨"
        }
    }

    private var recordButtonTitle: String {
        if model.isRecording { return "마무리" }
        if model.isBusy { return state.title }
        return "받아쓰기 시작"
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
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
