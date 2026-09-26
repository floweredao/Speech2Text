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
    public var inputDeviceUID: String?
    public private(set) var transcript = ""
    public private(set) var status = String(localized: "받아쓰기 준비가 됐습니다.")
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
    @ObservationIgnored private let audioFactory: @MainActor (String?) -> any AudioCapturing
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let isOffline: @MainActor () -> Bool
    @ObservationIgnored private let startTimeout: Duration
    @ObservationIgnored private let recordingLimit: Duration
    @ObservationIgnored private let finishTimeout: Duration

    public convenience init() {
        let network = NetworkPath()
        self.init(
            sessionFactory: { SonioxSession() },
            audioFactory: { AVAudioCapture(deviceUID: $0) },
            credentials: KeychainCredentialStore(),
            isOffline: { network.isOffline }
        )
    }

    init(
        sessionFactory: @escaping @MainActor () -> any STTSession,
        audioFactory: @escaping @MainActor (String?) -> any AudioCapturing,
        credentials: any CredentialStoring = KeychainCredentialStore(),
        isOffline: @escaping @MainActor () -> Bool = { false },
        startTimeout: Duration = .seconds(12),
        recordingLimit: Duration = .seconds(60),
        finishTimeout: Duration = .seconds(12)
    ) {
        self.sessionFactory = sessionFactory
        self.audioFactory = audioFactory
        self.credentials = credentials
        self.isOffline = isOffline
        self.startTimeout = startTimeout
        self.recordingLimit = recordingLimit
        self.finishTimeout = finishTimeout
    }

    public func start() { begin(audioFactory(inputDeviceUID)) }

    /// Recognizes a local audio file through the same Soniox session as microphone audio.
    /// Supported AVAudioFile formats are converted; `.pcm` means mono 16 kHz s16le.
    /// Files are limited to 60 seconds and finish automatically at EOF.
    public func start(audioFile: URL) { begin(FileAudioCapture(url: audioFile)) }

    private func begin(_ capture: any AudioCapturing) {
        guard !isBusy else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let refusal: AppError? = key.isEmpty ? .missingCredential(.soniox) : isOffline() ? .offline : nil
        if let refusal {
            hasError = true
            outcome = .failed
            hasCurrentTranscript = false
            status = refusal.localizedDescription
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
        status = String(localized: "마이크를 준비하고 있습니다.")
        armTimeout(startTimeout, context: String(localized: "음성 인식 시작"), epoch: epoch)
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard generation == epoch, !Task.isCancelled else { return }
                // The microphone starts at once and buffers while the provider connects, so the first
                // words are kept. A pending permission prompt comes first: Soniox drops idle sockets.
                let early = capture.promptsForPermission ? nil : connect(client, apiKey: key, epoch: epoch)
                let chunks = try await capture.start(format: .pcm16Mono16k)
                guard generation == epoch, !Task.isCancelled else { return }
                phase = .recording
                status = String(localized: "듣고 있습니다 · 연결 중…")
                let (provider, events) = try await (early ?? connect(client, apiKey: key, epoch: epoch)).value
                guard generation == epoch, !Task.isCancelled else { return }
                // Finishing while connecting already armed its own timeout; keep it.
                if phase == .recording {
                    status = String(localized: "듣고 있습니다.")
                    timerTask?.cancel()
                    timerTask = Task { [weak self, recordingLimit] in
                        do { try await Task.sleep(for: recordingLimit) } catch { return }
                        guard let self, self.generation == epoch else { return }
                        self.finish()
                    }
                }
                senderTask = Task { [weak self] in
                    do {
                        for try await chunk in chunks {
                            guard let self, self.generation == epoch, !Task.isCancelled else { return }
                            if !chunk.isEmpty { try await provider.sendAudio(chunk) }
                        }
                        guard let self, self.generation == epoch, !Task.isCancelled else { return }
                        self.beginFinishing(epoch: epoch)
                        try await provider.finish()
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
                status = result.isEmpty ? String(localized: "인식된 음성이 없습니다.") : String(localized: "받아쓰기를 마쳤습니다.")
                onFinal?(result)
            } catch { fail(error, epoch: epoch) }
        }
    }

    /// Opens the provider while audio buffers. A failed connection is retried once on a fresh session:
    /// no audio has been sent yet, so the retry loses nothing.
    private func connect(_ first: any STTSession, apiKey key: String, epoch: UUID)
        -> Task<(any STTSession, AsyncThrowingStream<TranscriptEvent, Error>), Error> {
        Task {
            guard generation == epoch else { throw AppError.cancelled }
            do {
                return (first, try await first.open(apiKey: key))
            } catch AppError.connectionFailed {
                guard generation == epoch else { throw AppError.cancelled }
                let retry = sessionFactory()
                session = retry
                if phase == .recording { status = String(localized: "듣고 있습니다 · 다시 연결 중…") }
                return (retry, try await retry.open(apiKey: key))
            }
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
        status = String(localized: "남은 음성을 마무리하고 있습니다.")
        armTimeout(finishTimeout, context: String(localized: "음성 인식 마무리"), epoch: epoch)
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
                status = String(localized: "API 키를 저장했습니다.")
            }
        } catch {
            if !isBusy, generation == epoch {
                hasError = true
                status = error.localizedDescription
            }
        }
    }

    public func loadKey() async { await load(from: credentials) }

    private func load(from store: any CredentialStoring) async {
        let previous = apiKey
        let epoch = generation
        do {
            let value = try await store.load(.soniox)
            guard apiKey == previous, !Task.isCancelled else { return }
            if let value { apiKey = value }
            if !isBusy, generation == epoch {
                hasError = false
                status = value == nil ? String(localized: "저장된 API 키가 없습니다.") : String(localized: "API 키를 불러왔습니다.")
            }
        } catch {
            if !isBusy, generation == epoch {
                hasError = true
                status = error.localizedDescription
            }
        }
    }
}
