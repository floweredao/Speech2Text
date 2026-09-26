import Foundation
import Observation

public enum SpeechPhase: Sendable {
    case idle, preparing, recording, finishing
}

public enum SpeechOutcome: Sendable {
    case none, completed, empty, cancelled, failed
}

/// Native Soniox dictation. An endpoint finalizes a turn, not the whole recording.
/// `onFinal` is called exactly once on successful session completion, including empty speech.
@MainActor @Observable public final class SpeechEngine {
    public var apiKey = ""
    public private(set) var transcript = ""
    public private(set) var status = "받아쓰기 준비가 됐습니다."
    public private(set) var phase = SpeechPhase.idle
    public private(set) var hasError = false
    public private(set) var outcome = SpeechOutcome.none
    public private(set) var hasCurrentTranscript = false
    public var isRecording: Bool { phase == .recording }
    public var isBusy: Bool { phase != .idle }
    public var onFinal: (@MainActor (String) -> Void)?
    public var onLiveText: (@MainActor (String) -> Void)?

    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var turns: [TranscriptUpdate] = []
    @ObservationIgnored private var lastFinalTranscript = ""
    @ObservationIgnored private var session: (any STTSession)?
    @ObservationIgnored private var audio: (any AudioCapturing)?
    @ObservationIgnored private(set) var runTask: Task<Void, Never>?
    @ObservationIgnored private var senderTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private let sessionFactory: @MainActor () -> any STTSession
    @ObservationIgnored private let audioFactory: @MainActor () -> any AudioCapturing
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let sourceCredentials: any CredentialStoring
    @ObservationIgnored private let startTimeout: Duration
    @ObservationIgnored private let recordingLimit: Duration
    @ObservationIgnored private let finishTimeout: Duration

    public convenience init() {
        self.init(
            sessionFactory: { SonioxSession() },
            audioFactory: { AVAudioCapture() },
            credentials: KeychainCredentialStore(),
            sourceCredentials: KeychainCredentialStore(service: "local.speech-to-action.credentials")
        )
    }

    init(
        sessionFactory: @escaping @MainActor () -> any STTSession,
        audioFactory: @escaping @MainActor () -> any AudioCapturing,
        credentials: any CredentialStoring = KeychainCredentialStore(),
        sourceCredentials: any CredentialStoring = KeychainCredentialStore(service: "local.speech-to-action.credentials"),
        startTimeout: Duration = .seconds(12),
        recordingLimit: Duration = .seconds(60),
        finishTimeout: Duration = .seconds(12)
    ) {
        self.sessionFactory = sessionFactory
        self.audioFactory = audioFactory
        self.credentials = credentials
        self.sourceCredentials = sourceCredentials
        self.startTimeout = startTimeout
        self.recordingLimit = recordingLimit
        self.finishTimeout = finishTimeout
    }

    public func start() { begin(audioFactory()) }

    /// Recognizes a local audio file through the same Soniox session as microphone audio.
    /// Supported AVAudioFile formats are converted; `.pcm` means mono 16 kHz s16le.
    /// Files are limited to 60 seconds and finish automatically at EOF.
    public func start(audioFile: URL) { begin(FileAudioCapture(url: audioFile)) }

    private func begin(_ capture: any AudioCapturing) {
        guard !isBusy else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            hasError = true
            outcome = .failed
            hasCurrentTranscript = false
            status = AppError.missingCredential(.soniox).localizedDescription
            return
        }
        let epoch = UUID()
        generation = epoch
        hasError = false
        outcome = .none
        hasCurrentTranscript = false
        turns = []
        let previousTranscript = lastFinalTranscript
        // Keep the previous transcript until new speech arrives, even if startup fails.
        let client = sessionFactory()
        session = client
        audio = capture
        phase = .preparing
        status = "음성 인식 연결을 준비하고 있습니다."
        armTimeout(startTimeout, context: "음성 인식 시작", epoch: epoch)
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard generation == epoch, !Task.isCancelled else { return }
                let events = try await client.open(apiKey: key)
                guard generation == epoch, !Task.isCancelled else { return }
                let chunks = try await capture.start(format: .pcm16Mono16k)
                guard generation == epoch, !Task.isCancelled else { return }
                phase = .recording
                status = "듣고 있습니다."
                timerTask?.cancel()
                timerTask = Task { [weak self, recordingLimit] in
                    do { try await Task.sleep(for: recordingLimit) } catch { return }
                    guard let self, self.generation == epoch else { return }
                    self.finish()
                }
                senderTask = Task { [weak self] in
                    do {
                        for try await chunk in chunks {
                            guard let self, self.generation == epoch, !Task.isCancelled else { return }
                            if !chunk.isEmpty { try await client.sendAudio(chunk) }
                        }
                        guard let self, self.generation == epoch, !Task.isCancelled else { return }
                        self.beginFinishing(epoch: epoch)
                        try await client.finish()
                    } catch { self?.fail(error, epoch: epoch) }
                }
                var completed = false
                for try await event in events {
                    guard generation == epoch, !Task.isCancelled else { return }
                    switch event {
                    case .status: break
                    case .update(let update): receive(update)
                    case .finished: completed = true
                    }
                }
                guard generation == epoch, !Task.isCancelled else { return }
                guard completed, phase == .finishing else {
                    throw AppError.invalidResponse("Provider ended without finalization")
                }
                await senderTask?.value
                guard generation == epoch, !Task.isCancelled else { return }
                await capture.stop()
                guard generation == epoch, !Task.isCancelled else { return }
                let result = Self.joined(turns.filter(\.isFinal))
                transcript = result.isEmpty ? previousTranscript : result
                if !result.isEmpty { lastFinalTranscript = result }
                hasCurrentTranscript = !result.isEmpty
                outcome = result.isEmpty ? .empty : .completed
                generation = UUID()
                timerTask?.cancel()
                session = nil
                audio = nil
                phase = .idle
                hasError = false
                status = result.isEmpty ? "인식된 음성이 없습니다." : "받아쓰기를 마쳤습니다."
                onFinal?(result)
            } catch { fail(error, epoch: epoch) }
        }
    }

    private func receive(_ update: TranscriptUpdate) {
        if let index = turns.firstIndex(where: { $0.turnID == update.turnID }) {
            guard !turns[index].isFinal, update.revision > turns[index].revision else { return }
            turns[index] = update
        } else {
            turns.append(update)
        }
        transcript = Self.joined(turns)
        hasCurrentTranscript = !transcript.isEmpty
        onLiveText?(transcript)
    }

    private static func joined(_ turns: [TranscriptUpdate]) -> String {
        turns.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public func finish() {
        if phase == .preparing { cancel(); return }
        guard phase == .recording, let audio else { return }
        beginFinishing(epoch: generation)
        stopTask = Task { await audio.stop() }
    }

    private func beginFinishing(epoch: UUID) {
        guard phase != .finishing else { return }
        phase = .finishing
        status = "남은 음성을 마무리하고 있습니다."
        armTimeout(finishTimeout, context: "음성 인식 마무리", epoch: epoch)
    }

    public func cancel() {
        hasError = false
        guard isBusy else { return }
        transcript = lastFinalTranscript
        hasCurrentTranscript = false
        outcome = .cancelled
        stop(with: AppError.cancelled.localizedDescription)
    }

    private func fail(_ error: Error, epoch: UUID) {
        guard generation == epoch else { return }
        hasError = true
        outcome = .failed
        stop(with: error.localizedDescription)
    }

    private func stop(with message: String) {
        generation = UUID()
        runTask?.cancel()
        senderTask?.cancel()
        timerTask?.cancel()
        let oldAudio = audio, oldSession = session
        audio = nil
        session = nil
        phase = .idle
        status = message
        // Each start owns a new capture and session, so old cleanup cannot stop a new run.
        stopTask = Task {
            await oldAudio?.stop()
            await oldSession?.cancel()
        }
    }

    private func armTimeout(_ duration: Duration, context: String, epoch: UUID) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.fail(AppError.timeout(context), epoch: epoch)
        }
    }

    public func saveKey() async {
        let epoch = generation
        do {
            try await credentials.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .soniox)
            if !isBusy, generation == epoch {
                hasError = false
                status = "API 키를 저장했습니다."
            }
        } catch {
            if !isBusy, generation == epoch {
                hasError = true
                status = error.localizedDescription
            }
        }
    }

    public func loadKey() async { await load(from: credentials) }

    /// Call only from the explicit import button. Never called by init, loadKey, or start.
    /// Import places the key in memory; saveKey persists it in Speech2Text's own service.
    public func importSourceKey() async { await load(from: sourceCredentials) }

    private func load(from store: any CredentialStoring) async {
        let previous = apiKey
        let epoch = generation
        do {
            let value = try await store.load(.soniox)
            guard apiKey == previous, !Task.isCancelled else { return }
            if let value { apiKey = value }
            if !isBusy, generation == epoch {
                hasError = false
                status = value == nil ? "저장된 API 키가 없습니다." : "API 키를 불러왔습니다."
            }
        } catch {
            if !isBusy, generation == epoch {
                hasError = true
                status = error.localizedDescription
            }
        }
    }
}
