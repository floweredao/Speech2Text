import SwiftUI

/// Settings › Key Management: the Soniox and Jev keys, each pasted, checked and deleted here, kept only in this
/// app's Keychain item. See DESIGN.md, "키 관리".
struct KeysView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            KeySection(model: model, service: .soniox)
            KeySection(model: model, service: .jev)
            Section {
                Text("키는 이 Mac의 키체인에만 저장해요. 파일로 남기거나 다른 기기와 동기화하지 않아요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("keys-storage-note")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, idealWidth: 480, maxWidth: 640, minHeight: 420, idealHeight: 540)
    }
}

private struct KeySection: View {
    @Bindable var model: AppModel
    let service: ServiceKey
    /// `State` struct instead of the `@State` macro: the CLT toolchain ships no SwiftUIMacros plugin.
    private let draftState = State(initialValue: "")
    private let confirmDeleteState = State(initialValue: false)
    private var draft: String { draftState.wrappedValue }

    private var stored: String { model.storedKey(service) }
    private var hasKey: Bool { !stored.isEmpty }
    private var busy: Bool { service == .soniox && model.speech.keyActivity != .idle }
    private var checking: Bool { model.checkingKeys.contains(service) }
    private var id: String { service.rawValue }

    var body: some View {
        Section {
            LabeledContent {
                statusBadge
                    .accessibilityIdentifier("keys-\(id)-status")
            } label: {
                Text(title)
                Text(purpose)
            }
            HStack(spacing: Spacing.s) {
                SecureField(hasKey ? String(localized: "새 키") : String(localized: "API 키"), text: draftState.projectedValue,
                            prompt: Text("키를 붙여넣으세요"))
                    .textContentType(.password)
                    .labelsHidden()
                    .disabled(busy)
                    .onSubmit(save)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("keys-\(id)-field")
                Button("저장", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    .help("이 앱 전용 키체인 항목에 저장해요.")
                    .accessibilityIdentifier("keys-\(id)-save")
            }
            HStack(spacing: Spacing.s) {
                Button("확인") { Task { await model.checkKey(service) } }
                    .disabled(!hasKey || busy || checking)
                    .help("저장된 키가 되는지 물어봐요. 요금은 들지 않아요.")
                    .accessibilityIdentifier("keys-\(id)-check")
                if checking {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(Text("확인하는 중…"))
                }
                Spacer()
                Button("지우기", role: .destructive) { confirmDeleteState.wrappedValue = true }
                    .disabled(!hasKey || busy)
                    .help("이 Mac의 키체인에서 이 키를 지워요.")
                    .accessibilityIdentifier("keys-\(id)-delete")
            }
            .confirmationDialog(deleteQuestion, isPresented: confirmDeleteState.projectedValue) {
                Button("삭제", role: .destructive, action: delete)
                    .accessibilityIdentifier("keys-\(id)-confirm-delete")
            } message: {
                Text(deleteConsequence)
            }
            if let note {
                Text(note.text)
                    .font(.caption)
                    .foregroundStyle(note.warning ? Color.warningText : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("keys-\(id)-message")
            }
            if !hasKey {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(missingGuidance)
                        .foregroundStyle(Color.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(consoleLinkTitle, destination: service.consoleURL)
                }
                .font(.caption)
                .accessibilityIdentifier("keys-\(id)-missing")
            }
        } header: {
            Text(service == .soniox ? "Soniox" : "Jev (TypeSafe)")
        }
    }

    private var statusBadge: some View {
        Label {
            Text(hasKey ? String(localized: "저장됨 \(ServiceKey.masked(stored))") : String(localized: "없음"))
                .foregroundStyle(hasKey ? Color.primary : Color.warningText)
                .monospacedDigit()
        } icon: {
            Image(systemName: hasKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(hasKey ? Color.green : Color.orange)
        }
        .fixedSize()
    }

    private var title: String {
        service == .soniox ? String(localized: "Soniox API 키") : String(localized: "Jev API 키")
    }

    private var purpose: String {
        switch service {
        case .soniox: String(localized: "받아쓰기에 써요. 녹음하는 동안 말소리를 Soniox로 보내 글로 바꿔요.")
        case .jev: String(localized: "말로 고치기에 써요. 명령처럼 들린 말과 앞 글 일부를 TypeSafe로 보내 명령인지 판단해요.")
        }
    }

    private var missingGuidance: String {
        switch service {
        case .soniox: String(localized: "키가 없으면 받아쓰기를 시작할 수 없어요. Soniox 콘솔에서 내 키를 만들어 붙여넣으세요.")
        case .jev: String(localized: "키가 없으면 명령처럼 들린 말도 모두 글로 써요. TypeSafe 콘솔에서 내 키를 만들어 붙여넣으세요.")
        }
    }

    private var consoleLinkTitle: String {
        service == .soniox ? String(localized: "Soniox 콘솔 열기") : String(localized: "TypeSafe 콘솔 열기")
    }

    private var deleteQuestion: String {
        service == .soniox ? String(localized: "저장된 Soniox 키를 지울까요?") : String(localized: "저장된 Jev 키를 지울까요?")
    }

    private var deleteConsequence: String {
        switch service {
        case .soniox: String(localized: "다시 받아쓰려면 키를 새로 붙여넣고 저장해야 해요.")
        case .jev: String(localized: "말로 고치기를 다시 쓰려면 키를 새로 붙여넣고 저장해야 해요.")
        }
    }

    /// The newest thing to say about this key: a check answer, else what saving or deleting did.
    private var note: (text: String, warning: Bool)? {
        if let check = model.keyChecks[service] {
            return switch check {
            case .valid: (String(localized: "키가 맞아요."), false)
            case .refused: (String(localized: "서비스가 이 키를 받지 않았어요. 키를 다시 확인해 주세요."), true)
            case .failed(let reason): (String(localized: "확인하지 못했어요(\(reason)). 인터넷 연결을 확인하고 다시 눌러 주세요."), true)
            }
        }
        switch service {
        case .soniox:
            if let activity = sonioxActivity { return (activity, false) }
            let message = model.speech.keyMessage
            return message.isEmpty ? nil : (message, model.speech.keyFailed)
        case .jev:
            return model.jevKeyMessage.isEmpty ? nil : (model.jevKeyMessage, model.jevKeyFailed)
        }
    }

    private var sonioxActivity: String? {
        switch model.speech.keyActivity {
        case .idle: nil
        case .saving: String(localized: "Keychain에 저장하는 중…")
        case .loading: String(localized: "Keychain에서 불러오는 중…")
        case .deleting: String(localized: "Keychain에서 지우는 중…")
        }
    }

    private func save() {
        let key = draft
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !busy else { return }
        switch service {
        case .soniox:
            Task {
                if await model.saveSonioxKey(key) { draftState.wrappedValue = "" }
            }
        case .jev:
            if model.saveJevKey(key) { draftState.wrappedValue = "" }
        }
    }

    private func delete() {
        switch service {
        case .soniox:
            model.forgetKeyCheck(.soniox)
            model.deleteKey()
        case .jev: model.deleteJevKey()
        }
    }
}
