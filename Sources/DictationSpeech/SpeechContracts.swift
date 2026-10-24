import Foundation

enum CaptureFormat: Sendable { case pcm16Mono16k }
enum SessionStatus: Sendable, Equatable { case configSent }
/// Recognized text with the time its first sound was spoken, in milliseconds of recorded audio.
struct TimedText: Sendable, Equatable {
    let text: String
    let startMs: Int?
    /// Soniox's 0-1 certainty for this token.
    var confidence: Double? = nil
    /// When the token's sound ended, on the same scale as `startMs`.
    var endMs: Int? = nil
}
struct TranscriptUpdate: Sendable, Equatable {
    let turnID: String
    let revision: Int
    let text: String
    let isFinal: Bool
    /// The tokens that make up `text`, in order.
    var spans: [TimedText] = []
}
enum TranscriptEvent: Sendable, Equatable {
    case status(SessionStatus), update(TranscriptUpdate), finished
}
protocol STTSession: Sendable {
    /// `translateTo` (a language code) makes the stream carry that translation instead of the spoken language.
    /// `text` is free-form context (example sentences) sent with `terms`; nil for none.
    func open(apiKey: String, terms: [String], text: String?, translateTo: String?) async throws -> AsyncThrowingStream<TranscriptEvent, Error>
    func sendAudio(_ pcm: Data) async throws
    /// Sends EOF after the caller has drained audio. Completion arrives on the event stream.
    func finish() async throws
    func cancel() async
}
extension STTSession {
    func open(apiKey: String, terms: [String] = []) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        try await open(apiKey: apiKey, terms: terms, text: nil, translateTo: nil)
    }
}
@MainActor protocol AudioCapturing: AnyObject {
    /// True when starting will show the system permission prompt, so the provider must not wait on it.
    var promptsForPermission: Bool { get }
    /// Seconds of audio captured so far, including audio still buffered before the provider connected.
    var capturedDuration: TimeInterval { get }
    /// Loudness of the latest audio, 0 (silence) to 1, for a level meter. Read by polling, never observed.
    var inputLevel: Float { get }
    func start(format: CaptureFormat) async throws -> AsyncThrowingStream<Data, Error>
    func stop() async
}
extension AudioCapturing {
    var promptsForPermission: Bool { false }
    var capturedDuration: TimeInterval { 0 }
    var inputLevel: Float { 0 }
}
enum CredentialKind: String, Sendable { case soniox }
protocol CredentialStoring: Sendable {
    func load(_ kind: CredentialKind) async throws -> String?
    func save(_ value: String, for kind: CredentialKind) async throws
    func delete(_ kind: CredentialKind) async throws
}
enum AppError: Error, Sendable, Equatable, LocalizedError {
    case missingCredential(CredentialKind), invalidResponse(String)
    case provider(code: Int?, message: String)
    case permissionDenied(String), audioOverflow, timeout(String), cancelled, inputDeviceUnavailable
    case microphoneSilent, microphoneInterrupted, offline, connectionFailed
    case microphoneStartFailed(device: String, status: Int32)
    case keychain(Int32), keychainDenied

    var errorDescription: String? {
        switch self {
        case .missingCredential: String(localized: "Soniox API 키를 입력해 주세요.")
        case .invalidResponse(let context): String(localized: "음성 인식 응답을 처리하지 못했어요: \(context)")
        case .provider(let code, let message): "Soniox\(code.map { " (\($0))" } ?? ""): \(message)"
        case .permissionDenied(let context): String(localized: "접근 권한이 필요해요: \(context)")
        case .audioOverflow: String(localized: "오디오 전송이 늦어져 녹음을 멈췄어요. 다시 시작해 주세요.")
        case .timeout(let context): String(localized: "응답을 기다리는 시간이 지났어요: \(context)")
        case .cancelled: String(localized: "받아쓰기를 취소했어요.")
        case .inputDeviceUnavailable: String(localized: "선택한 마이크를 찾을 수 없어요. 설정에서 다른 마이크를 골라 주세요.")
        case .microphoneSilent: String(localized: "마이크에서 소리가 들어오지 않아요. 다른 기기가 쓰고 있거나 macOS가 연결을 거부했을 수 있어요. 설정에서 다른 마이크를 골라 주세요.")
        case .microphoneInterrupted: String(localized: "녹음 중 마이크 연결이 바뀌어 받아쓰기를 멈췄어요. 다시 시작해 주세요.")
        case .microphoneStartFailed(let device, let status):
            String(localized: "'\(device)' 마이크를 열지 못했어요 (오디오 형식 또는 장치 오류 \(Int(status))). 장치 연결을 확인하거나 설정에서 다른 마이크를 골라 주세요.")
        case .offline: String(localized: "인터넷에 연결되어 있지 않아요. 연결을 확인한 뒤 다시 시작해 주세요.")
        case .connectionFailed: String(localized: "Soniox에 연결하지 못했어요. 인터넷 연결을 확인한 뒤 다시 시도해 주세요.")
        case .keychain: String(localized: "Keychain에 접근하지 못했어요. 잠시 뒤 다시 시도해 주세요.")
        case .keychainDenied: String(localized: "Keychain 접근을 허용하지 않아 키를 처리하지 못했어요.")
        }
    }
}
