import AppIntents

/// What a Shortcuts, Siri or Voice Control request does to dictation. Unlike the toggle shortcut, a spoken "start"
/// never ends a running dictation and a spoken "finish" never starts one, because the speaker may not see the overlay.
enum DictationRequest: Equatable {
    case start, finish

    enum Effect: Equatable { case start, finish, none }

    func effect(isRecording: Bool, isBusy: Bool) -> Effect {
        switch self {
        case .start: isBusy ? .none : .start
        case .finish: isRecording ? .finish : .none
        }
    }
}

/// Hands intent requests to the app delegate. An intent can arrive while macOS is still launching the app, so it
/// waits until the delegate has registered.
@MainActor
enum DictationIntentRoute {
    private static var handler: ((DictationRequest) -> Void)?
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    static func register(_ handle: @escaping (DictationRequest) -> Void) {
        handler = handle
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume() }
    }

    static func perform(_ request: DictationRequest) async {
        if handler == nil {
            await withCheckedContinuation { waiting.append($0) }
        }
        handler?(request)
    }
}

struct StartDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "받아쓰기 시작"
    static let description = IntentDescription("지금 선택한 입력 칸에 받아쓰기를 시작해요. 이미 받아쓰는 중이면 그대로 둬요.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await DictationIntentRoute.perform(.start)
        return .result()
    }
}

struct FinishDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "받아쓰기 끝내기"
    static let description = IntentDescription("받아쓰던 내용을 마무리해요. 받아쓰는 중이 아니면 아무것도 하지 않아요.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await DictationIntentRoute.perform(.finish)
        return .result()
    }
}

/// Siri phrases that work without making a shortcut first. Phrases are translated in AppShortcuts.strings.
struct Speech2TextShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start dictation in \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "받아쓰기 시작",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: FinishDictationIntent(),
            phrases: [
                "Finish dictation in \(.applicationName)",
                "Stop dictation in \(.applicationName)",
            ],
            shortTitle: "받아쓰기 끝내기",
            systemImageName: "stop.circle"
        )
    }
}
