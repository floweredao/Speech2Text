import Foundation
import Observation

public enum SpeechPhase: Sendable {
    case idle, preparing, recording, finishing
}

public enum SpeechOutcome: Sendable {
    case none, completed, empty, cancelled, failed
}

/// What the credential store is doing for the settings key row.
public enum KeyActivity: Sendable {
    case idle, saving, loading, deleting
}

/// Native Soniox dictation. An endpoint finalizes a turn, not the whole recording.
/// `onFinal` is called exactly once on successful session completion, including empty speech.
@MainActor @Observable public final class SpeechEngine {
    public var apiKey = ""
    public var inputDeviceUID: String?
    /// Words sent to Soniox as context when a dictation starts; changes apply to the next one.
    public var vocabulary: [String] = []
    /// A recording finishes by itself once this long passes without newly recognized text. Nil keeps listening.
    public var silenceLimit: Duration? = .seconds(30)
    /// The last recording was finished by `silenceLimit`, not by the user.
    public private(set) var finishedForSilence = false
    public private(set) var transcript = ""
    public private(set) var status = String(localized: "받아쓰기 준비가 됐어요.")
    public private(set) var phase = SpeechPhase.idle
    public private(set) var hasError = false {
        didSet { if !hasError { needsSettings = false } }
    }
    /// The current error can only be fixed in Settings (key, microphone, permission); retrying repeats it.
    public private(set) var needsSettings = false
    public private(set) var keyActivity = KeyActivity.idle
    /// Result of the last save, load, or delete, shown next to the key field rather than as a dictation error.
    public private(set) var keyMessage = ""
    public private(set) var keyFailed = false
    public private(set) var outcome = SpeechOutcome.none
    public private(set) var hasCurrentTranscript = false
    public var isRecording: Bool { phase == .recording }
    public var isBusy: Bool { phase != .idle }
    public var onFinal: (@MainActor (String) -> Void)?
    public var onLiveText: (@MainActor (String) -> Void)?
    /// Called with the whole transcript each time Soniox finalizes a turn (after a pause), while still recording.
    public var onTurnFinal: (@MainActor (String) -> Void)?

    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var turns: [TranscriptUpdate] = []
    @ObservationIgnored private var lastFinalTranscript = ""
    /// System uptime of the first recorded sample, the zero of Soniox token times.
    @ObservationIgnored private var audioOrigin: TimeInterval?
    @ObservationIgnored private(set) var inbox: TranscriptInbox?
    @ObservationIgnored private var session: (any STTSession)?
    @ObservationIgnored private var audio: (any AudioCapturing)?
    @ObservationIgnored private(set) var runTask: Task<Void, Never>?
    @ObservationIgnored private var senderTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
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
            audioFactory: { HALAudioCapture(deviceUID: $0) },
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
        recordingLimit: Duration = .seconds(30 * 60),
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

    /// True when `start()` would fail at once (no API key, or no network route).
    public var refusesStart: Bool { startRefusal != nil }

    private var startRefusal: AppError? {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missingCredential(.soniox)
            : isOffline() ? .offline : nil
    }

    private func begin(_ capture: any AudioCapturing) {
        guard !isBusy else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let refusal = startRefusal {
            hasError = true
            needsSettings = Self.needsSettings(refusal)
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
        audioOrigin = nil
        finishedForSilence = false
        let terms = vocabulary
        let previousTranscript = lastFinalTranscript
        // Keep the previous transcript until new speech arrives, even if startup fails.
        let client = sessionFactory()
        session = client
        audio = capture
        phase = .preparing
        status = String(localized: "마이크를 준비하고 있어요.")
        armTimeout(startTimeout, context: String(localized: "음성 인식 시작"), epoch: epoch)
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard generation == epoch, !Task.isCancelled else { return }
                // The microphone starts at once and buffers while the provider connects, so the first
                // words are kept. A pending permission prompt comes first: Soniox drops idle sockets.
                let early = capture.promptsForPermission ? nil : connect(client, apiKey: key, terms: terms, epoch: epoch)
                let chunks = try await capture.start(format: .pcm16Mono16k)
                guard generation == epoch, !Task.isCancelled else { return }
                audioOrigin = ProcessInfo.processInfo.systemUptime - capture.capturedDuration
                phase = .recording
                armSilenceLimit(epoch: epoch)
                status = String(localized: "듣고 있어요 · 연결 중…")
                let (provider, events) = try await (early ?? connect(client, apiKey: key, terms: terms, epoch: epoch)).value
                guard generation == epoch, !Task.isCancelled else { return }
                // Finishing while connecting already armed its own timeout; keep it.
                if phase == .recording {
                    status = String(localized: "듣고 있어요.")
                    timerTask?.cancel()
                    timerTask = Task { [weak self, recordingLimit] in
                        do { try await Task.sleep(for: recordingLimit) } catch { return }
                        guard let self, self.generation == epoch else { return }
                        self.finish()
                    }
                }
                // Audio never waits for the main actor: live typing's accessibility calls into a busy app hold it,
                // and audio queued behind them reached Soniox late, so text stalled until the user stopped.
                // stop() cancels this task whenever the generation changes.
                senderTask = Task.detached(priority: .userInitiated) { [weak self] in
                    do {
                        for try await chunk in chunks {
                            try Task.checkCancellation()
                            if !chunk.isEmpty { try await provider.sendAudio(chunk) }
                        }
                        try Task.checkCancellation()
                        guard await self?.audioEnded(epoch: epoch) == true else { return }
                        try await provider.finish()
                    } catch { await self?.fail(error, epoch: epoch) }
                }
                let inbox = TranscriptInbox()
                self.inbox = inbox
                Task.detached { await inbox.collect(events) }
                var completed = false
                while let batch = try await inbox.next() {
                    guard generation == epoch, !Task.isCancelled else { return }
                    var changed = false
                    for event in batch {
                        switch event {
                        case .status: break
                        case .update(let update): changed = receive(update) || changed
                        case .finished: completed = true
                        }
                    }
                    // Once per batch: revisions that arrived while live typing was busy are typed as one edit.
                    if changed {
                        armSilenceLimit(epoch: epoch)
                        onLiveText?(transcript)
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
                let result = joined(turns.filter(\.isFinal))
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
                if finishedForSilence, let seconds = silenceLimit.map({ Int($0.components.seconds) }) {
                    status = String(localized: "\(seconds)초 동안 말이 없어 받아쓰기를 마쳤어요.")
                } else {
                    status = result.isEmpty ? String(localized: "인식된 음성이 없어요.") : String(localized: "받아쓰기를 마쳤어요.")
                }
                onFinal?(result)
            } catch { fail(error, epoch: epoch) }
        }
    }

    /// Opens the provider while audio buffers. A failed connection is retried once on a fresh session:
    /// no audio has been sent yet, so the retry loses nothing.
    private func connect(_ first: any STTSession, apiKey key: String, terms: [String], epoch: UUID)
        -> Task<(any STTSession, AsyncThrowingStream<TranscriptEvent, Error>), Error> {
        Task {
            guard generation == epoch else { throw AppError.cancelled }
            do {
                return (first, try await first.open(apiKey: key, terms: terms))
            } catch AppError.connectionFailed {
                guard generation == epoch else { throw AppError.cancelled }
                let retry = sessionFactory()
                session = retry
                if phase == .recording { status = String(localized: "듣고 있어요 · 다시 연결 중…") }
                return (retry, try await retry.open(apiKey: key, terms: terms))
            }
        }
    }

    private func receive(_ update: TranscriptUpdate) -> Bool {
        if let index = turns.firstIndex(where: { $0.turnID == update.turnID }) {
            guard !turns[index].isFinal, update.revision > turns[index].revision else { return false }
            turns[index] = update
        } else {
            turns.append(update)
        }
        transcript = joined(turns)
        hasCurrentTranscript = !transcript.isEmpty
        if update.isFinal, phase == .recording { onTurnFinal?(transcript) }
        return true
    }

    /// Milliseconds of recorded audio at a system uptime (an `NSEvent.timestamp`), on the scale of Soniox token
    /// times. Nil until the microphone has started.
    public func audioMilliseconds(atUptime uptime: TimeInterval) -> Int? {
        audioOrigin.map { Int(((uptime - $0) * 1000).rounded()) }
    }

    /// The transcript made only of words whose sound started before `ms`. A word without a time counts as
    /// earlier, so text of unknown timing is never moved to a later point. The result is a prefix of `transcript`.
    public func transcript(spokenBefore ms: Int) -> String {
        joined(turns.map { turn in
            guard !turn.spans.isEmpty else { return turn }
            let before = turn.spans.prefix { ($0.startMs ?? Int.min) < ms }.map(\.text).joined()
            return TranscriptUpdate(turnID: turn.turnID, revision: turn.revision, text: before, isFinal: turn.isFinal)
        })
    }

    private func joined(_ turns: [TranscriptUpdate]) -> String {
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

    private func audioEnded(epoch: UUID) -> Bool {
        guard generation == epoch else { return false }
        beginFinishing(epoch: epoch)
        return true
    }

    /// Restarts the wait for new speech. Only a recording can be finished this way, never one already finishing.
    private func armSilenceLimit(epoch: UUID) {
        silenceTask?.cancel()
        guard let silenceLimit, phase == .recording else { return }
        silenceTask = Task { [weak self] in
            do { try await Task.sleep(for: silenceLimit) } catch { return }
            guard let self, self.generation == epoch, self.phase == .recording else { return }
            self.finishedForSilence = true
            self.finish()
        }
    }

    private func beginFinishing(epoch: UUID) {
        silenceTask?.cancel()
        guard phase != .finishing else { return }
        phase = .finishing
        status = String(localized: "남은 음성을 마무리하고 있어요.")
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
        needsSettings = Self.needsSettings(error)
        outcome = .failed
        stop(with: error.localizedDescription)
    }

    static func needsSettings(_ error: Error) -> Bool {
        switch error as? AppError {
        case .missingCredential, .inputDeviceUnavailable, .microphoneSilent, .microphoneStartFailed, .permissionDenied: true
        case .provider(let code, _): code == 401 || code == 403
        default: false
        }
    }

    private func stop(with message: String) {
        generation = UUID()
        runTask?.cancel()
        senderTask?.cancel()
        timerTask?.cancel()
        silenceTask?.cancel()
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
        guard keyActivity == .idle else { return }
        keyActivity = .saving
        defer { keyActivity = .idle }
        do {
            try await credentials.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: .soniox)
            reportKey(String(localized: "API 키를 저장했어요."))
        } catch { reportKey(error.localizedDescription, failed: true) }
    }

    public func loadKey() async {
        guard keyActivity == .idle else { return }
        keyActivity = .loading
        defer { keyActivity = .idle }
        let previous = apiKey
        do {
            let value = try await credentials.load(.soniox)
            guard apiKey == previous, !Task.isCancelled else { return }
            if let value { apiKey = value }
            reportKey(value == nil ? String(localized: "저장된 API 키가 없어요.") : String(localized: "API 키를 불러왔어요."))
        } catch { reportKey(error.localizedDescription, failed: true) }
    }

    public func deleteKey() async {
        guard keyActivity == .idle else { return }
        keyActivity = .deleting
        defer { keyActivity = .idle }
        do {
            try await credentials.delete(.soniox)
            apiKey = ""
            reportKey(String(localized: "저장된 API 키를 지웠어요."))
        } catch { reportKey(error.localizedDescription, failed: true) }
    }

    private func reportKey(_ message: String, failed: Bool = false) {
        keyMessage = message
        keyFailed = failed
    }
}

/// Provider events gathered off the main actor. The main actor takes everything that arrived while it was busy in
/// one batch, so live typing that is slower than the revisions gets the newest text instead of working off a backlog.
actor TranscriptInbox {
    private var events: [TranscriptEvent] = []
    private var end: Result<Void, Error>?
    private var reader: CheckedContinuation<[TranscriptEvent]?, Error>?
    private var holdWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func collect(_ stream: AsyncThrowingStream<TranscriptEvent, Error>) async {
        do {
            for try await event in stream { add(event) }
            close(.success(()))
        } catch { close(.failure(error)) }
    }

    /// Every event that arrived since the last call, waiting for one if none has; nil once the stream ended.
    func next() async throws -> [TranscriptEvent]? {
        if !events.isEmpty {
            defer { events = [] }
            return events
        }
        switch end {
        case .success: return nil
        case .failure(let error): throw error
        case nil: return try await withCheckedThrowingContinuation { reader = $0 }
        }
    }

    func waitUntilHolding(_ count: Int) async {
        if events.count >= count { return }
        await withCheckedContinuation { holdWaiters.append((count, $0)) }
    }

    private func add(_ event: TranscriptEvent) {
        events.append(event)
        if let reader {
            self.reader = nil
            reader.resume(returning: events)
            events = []
        }
        let ready = holdWaiters.filter { $0.count <= events.count }
        holdWaiters.removeAll { $0.count <= events.count }
        ready.forEach { $0.continuation.resume() }
    }

    private func close(_ result: Result<Void, Error>) {
        end = result
        guard let reader else { return }
        self.reader = nil
        switch result {
        case .success: reader.resume(returning: nil)
        case .failure(let error): reader.resume(throwing: error)
        }
    }
}
