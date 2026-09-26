import Foundation

// Speech-only subset of Speech-to-action/SpeechToActionCore/Contracts.swift.
enum CaptureFormat: Sendable { case pcm16Mono16k }
enum SessionStatus: Sendable, Equatable { case configSent }
struct TranscriptUpdate: Sendable, Equatable {
    let turnID: String
    let revision: Int
    let text: String
    let isFinal: Bool
}
enum TranscriptEvent: Sendable, Equatable {
    case status(SessionStatus), update(TranscriptUpdate), finished
}
protocol STTSession: Sendable {
    func open(apiKey: String) async throws -> AsyncThrowingStream<TranscriptEvent, Error>
    func sendAudio(_ pcm: Data) async throws
    /// Sends EOF after the caller has drained audio. Completion arrives on the event stream.
    func finish() async throws
    func cancel() async
}
@MainActor protocol AudioCapturing: AnyObject {
    /// True when starting will show the system permission prompt, so the provider must not wait on it.
    var promptsForPermission: Bool { get }
    func start(format: CaptureFormat) async throws -> AsyncThrowingStream<Data, Error>
    func stop() async
}
extension AudioCapturing {
    var promptsForPermission: Bool { false }
}
enum CredentialKind: String, Sendable { case soniox }
protocol CredentialStoring: Sendable {
    func load(_ kind: CredentialKind) async throws -> String?
    func save(_ value: String, for kind: CredentialKind) async throws
}
enum AppError: Error, Sendable, Equatable, LocalizedError {
    case missingCredential(CredentialKind), invalidResponse(String)
    case provider(code: Int?, message: String)
    case permissionDenied(String), audioOverflow, timeout(String), cancelled, inputDeviceUnavailable
    case microphoneSilent, microphoneInterrupted, offline, connectionFailed

    var errorDescription: String? {
        switch self {
        case .missingCredential: "Soniox API 키를 입력해 주세요."
        case .invalidResponse(let context): "음성 인식 응답을 처리할 수 없습니다: \(context)"
        case .provider(let code, let message): "Soniox\(code.map { " (\($0))" } ?? ""): \(message)"
        case .permissionDenied(let context): "접근 권한이 필요합니다: \(context)"
        case .audioOverflow: "오디오 전송이 지연되어 녹음을 중단했습니다. 다시 시작해 주세요."
        case .timeout(let context): "응답 대기 시간이 초과됐습니다: \(context)"
        case .cancelled: "받아쓰기를 취소했습니다."
        case .inputDeviceUnavailable: "선택한 마이크를 찾을 수 없습니다. 설정에서 다른 마이크를 고르세요."
        case .microphoneSilent: "마이크에서 소리가 들어오지 않습니다. 다른 기기가 쓰고 있거나 macOS가 연결을 거부했을 수 있어요. 설정에서 다른 마이크를 고르세요."
        case .microphoneInterrupted: "녹음 중 마이크 연결이 바뀌어 받아쓰기를 멈췄습니다. 다시 시작해 주세요."
        case .offline: "인터넷에 연결되어 있지 않습니다. 연결을 확인한 뒤 다시 시작해 주세요."
        case .connectionFailed: "Soniox에 연결하지 못했습니다. 인터넷 연결을 확인한 뒤 다시 시도해 주세요."
        }
    }
}
