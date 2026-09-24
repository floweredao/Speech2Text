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
    func start(format: CaptureFormat) async throws -> AsyncThrowingStream<Data, Error>
    func stop() async
}
enum CredentialKind: String, Sendable { case soniox }
protocol CredentialStoring: Sendable {
    func load(_ kind: CredentialKind) async throws -> String?
    func save(_ value: String, for kind: CredentialKind) async throws
}
enum AppError: Error, Sendable, Equatable, LocalizedError {
    case missingCredential(CredentialKind), invalidResponse(String)
    case permissionDenied(String), audioOverflow, timeout(String), cancelled

    var errorDescription: String? {
        switch self {
        case .missingCredential: "Soniox API 키를 입력해 주세요."
        case .invalidResponse(let context): "음성 인식 응답을 처리할 수 없습니다: \(context)"
        case .permissionDenied(let context): "접근 권한이 필요합니다: \(context)"
        case .audioOverflow: "오디오 전송이 지연되어 녹음을 중단했습니다. 다시 시작해 주세요."
        case .timeout(let context): "응답 대기 시간이 초과됐습니다: \(context)"
        case .cancelled: "받아쓰기를 취소했습니다."
        }
    }
}
