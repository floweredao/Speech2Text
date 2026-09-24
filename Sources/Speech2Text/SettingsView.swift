import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    private var state: DictationDisplayState { DictationDisplayState(model: model) }
    private var keyIsEmpty: Bool { model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Form {
            statusSection
            keySection
            permissionSection
            shortcutSection
            overlaySection
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 600)
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            LabeledContent("상태") {
                Label(state.phase == .idle ? model.status : state.title, systemImage: statusSymbol)
                    .foregroundStyle(state.phase == .error ? Color.orange : Color.primary)
                    .accessibilityIdentifier("settings-status")
            }
            if state.phase == .error {
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.feedback.isEmpty {
                Text(model.feedback)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-feedback")
            }
            HStack {
                Button(recordButtonTitle, systemImage: model.isRecording ? "stop.fill" : "mic.fill") {
                    model.toggleRecording()
                }
                .disabled(model.isBusy && !model.isRecording)
                .accessibilityIdentifier("settings-record")
                if model.isBusy {
                    Button("취소", role: .cancel) { model.cancel() }
                        .accessibilityIdentifier("settings-cancel")
                }
            }
        } header: {
            Text("받아쓰기")
        }
    }

    private var keySection: some View {
        Section {
            SecureField("Soniox API 키", text: $model.apiKey, prompt: Text("키를 입력하세요"))
                .textContentType(.password)
                .accessibilityIdentifier("settings-api-key")
            HStack {
                Button("저장") { model.saveKey() }
                    .disabled(keyIsEmpty)
                    .help("이 앱 전용 Keychain 항목에 저장합니다.")
                    .accessibilityIdentifier("settings-save-key")
                Button("불러오기") { model.loadKey() }
                    .help("이 앱의 Keychain 항목에서 불러옵니다.")
                    .accessibilityIdentifier("settings-load-key")
                Spacer()
                Button("Speech-to-action에서 가져오기") { model.importSourceKey() }
                    .help("Speech-to-action이 저장한 Soniox 키를 이번 한 번만 읽어옵니다.")
                    .accessibilityIdentifier("settings-import-key")
            }
            if let keyStatus {
                Text(keyStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-key-status")
            }
        } header: {
            Text("Soniox API 키")
        } footer: {
            Text("키는 메모리에만 있다가 저장을 누를 때 이 앱의 Keychain에 저장돼요. 가져오기는 버튼을 누를 때만 Speech-to-action의 키를 읽어 입력 칸에 넣으며, 계속 쓰려면 저장을 눌러 주세요.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionSection: some View {
        Section {
            LabeledContent("손쉬운 사용") {
                HStack {
                    Label(model.accessibilityGranted ? "허용됨" : "필요함",
                          systemImage: model.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.accessibilityGranted ? Color.green : Color.orange)
                        .accessibilityIdentifier("settings-accessibility-status")
                    if !model.accessibilityGranted {
                        Button("허용 요청") { model.requestAccessibility() }
                            .accessibilityIdentifier("settings-request-accessibility")
                    }
                    Button("시스템 설정 열기") { openPrivacyPane("Privacy_Accessibility") }
                }
            }
            LabeledContent("마이크") {
                Button("시스템 설정 열기") { openPrivacyPane("Privacy_Microphone") }
            }
        } header: {
            Text("권한")
        } footer: {
            Text("손쉬운 사용 권한이 있어야 받아쓰기를 입력 칸에 직접 넣을 수 있어요. 마이크 권한은 처음 녹음할 때 macOS가 물어봐요.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutSection: some View {
        Section {
            LabeledContent("받아쓰기 시작 / 마무리") {
                Text("⌃⌥D").font(.body.monospaced()).accessibilityLabel("Control Option D")
            }
            LabeledContent("마지막 받아쓰기 붙여넣기") {
                Text("⌃⌥V").font(.body.monospaced()).accessibilityLabel("Control Option V")
            }
            Toggle("끝나면 자동으로 입력", isOn: $model.autoInsert)
                .accessibilityIdentifier("settings-auto-insert")
        } header: {
            Text("단축키와 입력")
        } footer: {
            Text("말하는 동안의 중간 결과는 화면에만 보여요. 마무리된 최종 결과만, 시작할 때 선택돼 있던 입력 칸이 그대로일 때 입력해요. 입력할 수 없으면 결과를 보관하니 복사하거나 ⌃⌥V로 붙여넣으세요.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var overlaySection: some View {
        Section {
            Button("받아쓰기 표시 열기") {
                model.overlayVisible = true
            }
            .accessibilityIdentifier("settings-show-overlay")
        } header: {
            Text("화면 위쪽 표시")
        } footer: {
            Text("표시는 다른 앱의 키보드 포커스를 가져가지 않아요. 결과는 닫거나 다음 받아쓰기를 시작할 때까지 남아 있어요.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Helpers

    private var recordButtonTitle: String {
        if model.isRecording { return "마무리" }
        if model.isBusy { return state.title }
        return "받아쓰기 시작"
    }

    private var statusSymbol: String {
        switch state.phase {
        case .recording: "record.circle"
        case .connecting, .finalizing: "hourglass"
        default: state.symbol
        }
    }

    private var keyStatus: String? {
        keyIsEmpty ? "키가 없으면 받아쓰기를 시작할 수 없어요." : nil
    }

    private func refreshPermissions() {
        model.accessibilityGranted = AXIsProcessTrusted()
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
