import AVFoundation
import Foundation
import Observation
import Security
import Testing
@testable import DictationSpeech

actor TestSocket: SocketTransport {
    private(set) var sent: [SocketFrame] = []
    private(set) var closed = false
    private(set) var connections = 0
    private var frames: [SocketFrame] = []
    private var receiver: CheckedContinuation<SocketFrame, any Error>?
    private var sentWaiters: [(SocketFrame, CheckedContinuation<Void, Never>)] = []
    private var blockedSend: CheckedContinuation<Void, any Error>?
    private var blockEOF = false
    private var blockConfig = false
    private var refusing = false
    private var connectWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Signalled for every audio frame, so a test can wait for audio while it holds the main actor.
    nonisolated let audioSent = DispatchSemaphore(value: 0)

    private(set) var apiKey: String?
    func connect(url: URL, apiKey: String) {
        self.apiKey = apiKey
        connections += 1
        connectWaiters.forEach { $0.resume() }
        connectWaiters.removeAll()
    }
    func holdEOF() { blockEOF = true }
    /// Stalls the first (configuration) frame the way a slow WebSocket handshake does.
    func holdConfig() { blockConfig = true }
    func releaseConfig() {
        blockConfig = false
        blockedSend?.resume()
        blockedSend = nil
    }
    func refuseConnection() { refusing = true }
    func send(_ frame: SocketFrame) async throws {
        guard !closed else { throw AppError.cancelled }
        if refusing { throw URLError(.notConnectedToInternet) }
        let isConfig = sent.isEmpty
        sent.append(frame)
        if case .binary = frame { audioSent.signal() }
        let ready = sentWaiters.filter { $0.0 == frame }
        sentWaiters.removeAll { $0.0 == frame }
        for (_, waiter) in ready { waiter.resume() }
        if (blockEOF && frame == .text("")) || (blockConfig && isConfig) {
            try await withCheckedThrowingContinuation { blockedSend = $0 }
        }
    }
    func waitUntilConnected() async {
        if connections > 0 { return }
        await withCheckedContinuation { connectWaiters.append($0) }
    }
    func waitUntilClosed() async {
        if closed { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }
    func waitUntilSent(_ frame: SocketFrame) async {
        if sent.contains(frame) { return }
        await withCheckedContinuation { sentWaiters.append((frame, $0)) }
    }
    func receive() async throws -> SocketFrame {
        if !frames.isEmpty { return frames.removeFirst() }
        guard !closed else { throw AppError.cancelled }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func push(_ frame: SocketFrame) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: frame)
        } else { frames.append(frame) }
    }
    func close() {
        closed = true
        receiver?.resume(throwing: AppError.cancelled)
        receiver = nil
        blockedSend?.resume(throwing: AppError.cancelled)
        blockedSend = nil
        closeWaiters.forEach { $0.resume() }
        closeWaiters.removeAll()
    }
}

@MainActor final class TestAudio: AudioCapturing {
    let pair = AsyncThrowingStream<Data, Error>.makeStream()
    var capturedDuration: TimeInterval = 0
    private(set) var starts = 0
    private(set) var stops = 0
    var startError: AppError?
    private var holdsStart = false
    private var gate: CheckedContinuation<Void, Never>?
    /// Keeps `start` pending, like a microphone that is still waking up.
    func holdStart() { holdsStart = true }
    func releaseStart() {
        holdsStart = false
        gate?.resume()
        gate = nil
    }
    func start(format: CaptureFormat) async throws -> AsyncThrowingStream<Data, Error> {
        starts += 1
        if holdsStart { await withCheckedContinuation { gate = $0 } }
        if let startError { throw startError }
        return pair.stream
    }
    func stop() async {
        stops += 1
        pair.continuation.finish()
    }
}

actor TestCredentials: CredentialStoring {
    private(set) var loads = 0
    private(set) var saves = 0
    private(set) var value: String?
    private var gate: CheckedContinuation<Void, Never>?
    private var holding = false
    init(_ value: String? = nil) { self.value = value }
    func load(_ kind: CredentialKind) -> String? { loads += 1; return value }
    func save(_ value: String, for kind: CredentialKind) async throws {
        guard !value.isEmpty else { throw AppError.missingCredential(kind) }
        if holding { await withCheckedContinuation { gate = $0 } }
        saves += 1
        self.value = value
    }
    func delete(_ kind: CredentialKind) { value = nil }
    func holdSave() { holding = true }
    func releaseSave() {
        holding = false
        gate?.resume()
        gate = nil
    }
}

// Swift Testing's suite deadline bounds every subscription. No polling or fixed delays.
@MainActor private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
    while !predicate() {
        try Task.checkCancellation()
        let change = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        withObservationTracking {
            _ = predicate()
        } onChange: {
            change.continuation.yield(())
            change.continuation.finish()
        }
        if predicate() { return }
        for await _ in change.stream { break }
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor struct SpeechEngineTests {
    private let pcm = Data(repeating: 7, count: 640)

    private func engine(_ socket: TestSocket, _ audio: TestAudio,
                        recordingLimit: Duration = .seconds(60),
                        finishTimeout: Duration = .seconds(12)) -> SpeechEngine {
        let engine = SpeechEngine(
            sessionFactory: { SonioxSession(transport: socket) },
            audioFactory: { _ in audio },
            recordingLimit: recordingLimit,
            finishTimeout: finishTimeout
        )
        engine.apiKey = "fixture"
        return engine
    }

    @Test func entireSessionFinalIsOnceAfterEOFNotEndpointOrRevision() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        var finals: [String] = []
        engine.onFinal = { finals.append($0) }
        audio.pair.continuation.yield(pcm)
        engine.start()
        #expect(engine.phase == .preparing)
        await socket.waitUntilSent(.binary(pcm))
        #expect(engine.isRecording)
        #expect(engine.phase == .recording)
        #expect(!engine.hasError)
        await socket.push(.text(#"{"tokens":[{"text":"wrong","is_final":false}]}"#))
        try await waitUntil { engine.transcript == "wrong" }
        #expect(finals.isEmpty)
        await socket.push(.text(#"{"tokens":[{"text":"First.","is_final":true},{"text":"<end>","is_final":true},{"text":"wrong second","is_final":false}]}"#))
        try await waitUntil { engine.transcript == "First. wrong second" }
        #expect(finals.isEmpty)
        engine.finish()
        engine.finish()
        await socket.waitUntilSent(.text(""))
        #expect(!engine.isRecording)
        #expect(engine.isBusy)
        #expect(engine.phase == .finishing)
        #expect(finals.isEmpty)
        await socket.push(.text(#"{"tokens":[{"text":"Second.","is_final":true}],"finished":true}"#))
        await engine.runTask?.value
        #expect(engine.transcript == "First. Second.")
        #expect(finals == ["First. Second."])
        #expect(!engine.isBusy)
        #expect(engine.phase == .idle)
        #expect(!engine.hasError)
        #expect(await socket.sent.filter { $0 == .text("") }.count == 1)
        #expect(await socket.sent.contains(.binary(Data())) == false)
        await socket.push(.text(#"{"tokens":[{"text":"late","is_final":true}],"finished":true}"#))
        engine.finish()
        #expect(finals.count == 1)
    }

    /// Regression (late text in the next field): words spoken before the user pressed Enter or clicked another field
    /// were recognized after it and typed there. The split follows when each word was spoken, not when it arrived.
    @Test func textSpokenBeforeACutFollowsSpeechTimeNotArrival() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        await socket.push(.text(#"{"tokens":[{"text":"첫","is_final":true,"start_ms":0},{"text":" 문장","is_final":true,"start_ms":400},{"text":"<end>","is_final":true},{"text":" 둘째","is_final":false,"start_ms":2100},{"text":" 문장","is_final":false,"start_ms":2600}]}"#))
        try await waitUntil { engine.transcript == "첫 문장 둘째 문장" }
        #expect(engine.spokenTurns(from: 2500) == [SpokenTurn(text: " 문장", isFinal: false)])
        #expect(engine.spokenTurns(from: 300) == [SpokenTurn(text: " 문장", isFinal: true),
                                                  SpokenTurn(text: " 둘째 문장", isFinal: false)])
        #expect(engine.spokenTurns(from: 9000).isEmpty)
        #expect(engine.spokenTurns(from: nil) == [SpokenTurn(text: "첫 문장", isFinal: true),
                                                  SpokenTurn(text: " 둘째 문장", isFinal: false)])
        engine.cancel()
    }

    /// The pause before a turn is the silence between word sounds, not the time between arrivals.
    @Test func eachTurnCarriesTheSilenceBeforeIt() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        await socket.push(.text(#"{"tokens":[{"text":"첫","is_final":true,"start_ms":0,"end_ms":300},{"text":" 문장","is_final":true,"start_ms":400,"end_ms":900},{"text":"<end>","is_final":true},{"text":" 지워","is_final":true,"start_ms":1450,"end_ms":1800},{"text":"<end>","is_final":true},{"text":" 둘째","is_final":false,"start_ms":2500}]}"#))
        try await waitUntil { engine.transcript == "첫 문장 지워 둘째" }
        #expect(engine.spokenTurns(from: nil).map(\.pauseBeforeMs) == [nil, 550, 700])
        #expect(engine.spokenTurns(from: 1000).map(\.pauseBeforeMs) == [550, 700])
        engine.cancel()
    }

    /// A word already under way when the user moved on belongs to the old field, even when it was cut into tokens.
    @Test func aWordCutInTokensAtTheSplitStaysBeforeIt() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        await socket.push(.text(#"{"tokens":[{"text":"격리된","is_final":false,"start_ms":0},{"text":" 바다","is_final":false,"start_ms":500},{"text":"쓰기","is_final":false,"start_ms":800},{"text":" 입력","is_final":false,"start_ms":1200}]}"#))
        try await waitUntil { engine.transcript == "격리된 바다쓰기 입력" }
        #expect(engine.spokenTurns(from: 700) == [SpokenTurn(text: " 입력", isFinal: false)])
        engine.cancel()
    }

    /// Soniox times count from the first recorded sample, which can predate the moment recording was reported.
    @Test func audioClockStartsAtTheFirstRecordedSample() async throws {
        let socket = TestSocket(), audio = TestAudio()
        audio.capturedDuration = 2
        let engine = engine(socket, audio)
        #expect(engine.audioMilliseconds(atUptime: ProcessInfo.processInfo.systemUptime) == nil)
        audio.pair.continuation.yield(pcm)
        let before = ProcessInfo.processInfo.systemUptime
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        let after = ProcessInfo.processInfo.systemUptime
        let now = try #require(engine.audioMilliseconds(atUptime: after))
        #expect(now >= 2000 && now <= 2000 + Int(((after - before) * 1000).rounded(.up)))
        engine.cancel()
    }

    @Test func providerFailureRetainsVisibleTextAndNeverCallsFinal() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        var finals: [String] = []
        engine.onFinal = { finals.append($0) }
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        await socket.push(.text(#"{"tokens":[{"text":"Keep this","is_final":false}]}"#))
        try await waitUntil { engine.transcript == "Keep this" }
        await socket.push(.closed(1006))
        await engine.runTask?.value
        #expect(engine.transcript == "Keep this")
        #expect(!engine.isBusy)
        #expect(engine.hasError)
        #expect(finals.isEmpty)
        engine.apiKey = ""
        engine.start()
        #expect(engine.transcript == "Keep this")
        #expect(engine.hasError)
        engine.cancel()
        #expect(!engine.hasError)
    }

    @Test func dictionaryTermsReachTheProviderAndAPauseReportsTheTranscript() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        engine.vocabulary = ["OMO", "센파이"]
        var turnFinals: [String] = []
        engine.onTurnFinal = { turnFinals.append($0) }
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        guard case .text(let text) = await socket.sent.first else { Issue.record("Missing configuration"); return }
        let config = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect((config["context"] as? [String: Any])?["terms"] as? [String] == ["OMO", "센파이"])
        #expect((config["context"] as? [String: Any])?["text"] == nil)
        await socket.push(.text(#"{"tokens":[{"text":"센파이 호출","is_final":false}]}"#))
        try await waitUntil { engine.transcript == "센파이 호출" }
        #expect(turnFinals.isEmpty)
        await socket.push(.text(#"{"tokens":[{"text":"센파이 호출","is_final":true},{"text":"<end>","is_final":true}]}"#))
        await socket.push(.text(#"{"tokens":[{"text":" 다음","is_final":false}]}"#))
        try await waitUntil { engine.transcript == "센파이 호출 다음" }
        #expect(turnFinals == ["센파이 호출"])
        engine.cancel()
        await engine.runTask?.value
    }

    @Test func contextTextReachesTheProviderWithTheTerms() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        engine.vocabulary = ["점"]
        engine.contextText = "빨간 점 하나 찍어 줘."
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        guard case .text(let text) = await socket.sent.first else { Issue.record("Missing configuration"); return }
        let config = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let context = try #require(config["context"] as? [String: Any])
        #expect(context["terms"] as? [String] == ["점"])
        #expect(context["text"] as? String == "빨간 점 하나 찍어 줘.")
        engine.cancel()
        await engine.runTask?.value
    }

    @Test func cancelDiscardsUnconfirmedTextFromPasteSurface() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        await socket.push(.text(#"{"tokens":[{"text":"must not paste cancelled text","is_final":false}]}"#))
        try await waitUntil { !engine.transcript.isEmpty }
        engine.cancel()
        await engine.runTask?.value
        #expect(engine.transcript.isEmpty)
        #expect(engine.outcome == .cancelled)
        #expect(!engine.hasCurrentTranscript)
    }

    @Test func liveTextFollowsEveryRevisionAndStopsAfterCancel() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        var live: [String] = []
        engine.onLiveText = { live.append($0) }
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        await socket.push(.text(#"{"tokens":[{"text":"메모 열어","is_final":false}]}"#))
        try await waitUntil { engine.transcript == "메모 열어" }
        await socket.push(.text(#"{"tokens":[{"text":"메모장 ","is_final":true},{"text":"열어 줘","is_final":false}]}"#))
        try await waitUntil { engine.transcript == "메모장 열어 줘" }
        #expect(live == ["메모 열어", "메모장 열어 줘"])
        engine.cancel()
        await socket.push(.text(#"{"tokens":[{"text":"late","is_final":false}]}"#))
        await engine.runTask?.value
        #expect(live.count == 2)
    }

    /// Regression: a provisional word Soniox dropped at an endpoint stayed in the transcript and the typed field.
    @Test func aProvisionalWordDroppedAtAnEndpointLeavesTheLiveText() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        var live: [String] = []
        engine.onLiveText = { live.append($0) }
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        await socket.push(.text(#"{"tokens":[{"text":"첫 문장.","is_final":true},{"text":"<end>","is_final":true},{"text":" 음","is_final":false}]}"#))
        try await waitUntil { engine.transcript == "첫 문장. 음" }
        await socket.push(.text(#"{"tokens":[{"text":"<end>","is_final":true}]}"#))
        try await waitUntil { engine.transcript == "첫 문장." }
        #expect(live.last == "첫 문장.")
        engine.cancel()
        await engine.runTask?.value
    }

    /// Live typing makes accessibility calls into the target app on the main actor, and a busy app answers slowly.
    /// Audio waiting for the main actor reached Soniox late, so text stalled until the user stopped.
    @Test func audioKeepsReachingTheProviderWhileTheMainActorIsBusy() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        let later = Data(repeating: 8, count: 640)
        var deliveredWhileBusy: Bool?
        engine.onLiveText = { _ in
            guard deliveredWhileBusy == nil else { return }
            while socket.audioSent.wait(timeout: .now()) == .success {}
            audio.pair.continuation.yield(later)
            deliveredWhileBusy = socket.audioSent.wait(timeout: .now() + 3) == .success
        }
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        await socket.push(.text(#"{"tokens":[{"text":"말하는 중","is_final":false}]}"#))
        try await waitUntil { engine.transcript == "말하는 중" }
        #expect(deliveredWhileBusy == true)
        engine.cancel()
        await engine.runTask?.value
    }

    /// Revisions that arrive while live typing is still busy are not replayed one by one, which would leave typing
    /// further behind with every revision; the next delivery is the newest text.
    @Test func revisionsArrivingWhileLiveTextIsBusyAreDeliveredOnceAsTheNewest() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        var live: [String] = []
        let caughtUp = DispatchSemaphore(value: 0)
        engine.onLiveText = { text in
            live.append(text)
            guard live.count == 1, let inbox = engine.inbox else { return }
            Task.detached {
                await socket.push(.text(#"{"tokens":[{"text":"하나 둘","is_final":false}]}"#))
                await socket.push(.text(#"{"tokens":[{"text":"하나 둘 셋","is_final":false}]}"#))
                await inbox.waitUntilHolding(2)
                caughtUp.signal()
            }
            #expect(caughtUp.wait(timeout: .now() + 3) == .success)
        }
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        await socket.push(.text(#"{"tokens":[{"text":"하나","is_final":false}]}"#))
        try await waitUntil { engine.transcript == "하나 둘 셋" }
        #expect(live == ["하나", "하나 둘 셋"])
        #expect(engine.transcript == "하나 둘 셋")
        engine.cancel()
        await engine.runTask?.value
    }

    @Test func turnsAreJoinedWithASingleSpace() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        var live: [String] = []
        engine.onLiveText = { live.append($0) }
        audio.pair.continuation.finish()
        engine.start()
        await socket.waitUntilSent(.text(""))
        await socket.push(.text(#"{"tokens":[{"text":"첫 문장.","is_final":true},{"text":"<end>","is_final":true},{"text":" 둘째","is_final":false}]}"#))
        try await waitUntil { live.count == 2 || engine.transcript.hasSuffix("둘째") }
        #expect(live.last == "첫 문장. 둘째")
        await socket.push(.text(#"{"tokens":[{"text":" 둘째 문장.","is_final":true}],"finished":true}"#))
        await engine.runTask?.value
        #expect(engine.transcript == "첫 문장. 둘째 문장.")
    }

    @Test func repeatingTheSameSentenceIsReportedAsCurrent() async throws {
        let first = TestSocket(), second = TestSocket()
        var sessions = [SonioxSession(transport: first), SonioxSession(transport: second)]
        let audios = [TestAudio(), TestAudio()]
        var captures = audios
        let engine = SpeechEngine(sessionFactory: { sessions.removeFirst() }, audioFactory: { _ in captures.removeFirst() })
        engine.apiKey = "fixture"
        for (socket, audio) in zip([first, second], audios) {
            audio.pair.continuation.finish()
            engine.start()
            await socket.waitUntilSent(.text(""))
            await socket.push(.text(#"{"tokens":[{"text":"같은 문장","is_final":true}],"finished":true}"#))
            await engine.runTask?.value
            #expect(engine.outcome == .completed)
            #expect(engine.hasCurrentTranscript)
        }
    }

    @Test func cancelThenRestartRejectsOldSessionAndLateFinal() async throws {
        let oldSocket = TestSocket(), newSocket = TestSocket()
        let oldAudio = TestAudio(), newAudio = TestAudio()
        var sessions = [SonioxSession(transport: oldSocket), SonioxSession(transport: newSocket)]
        var captures = [oldAudio, newAudio]
        let engine = SpeechEngine(sessionFactory: { sessions.removeFirst() },
                                  audioFactory: { _ in captures.removeFirst() })
        engine.apiKey = "fixture"
        var finals: [String] = []
        engine.onFinal = { finals.append($0) }
        oldAudio.pair.continuation.yield(pcm)
        engine.start()
        await oldSocket.waitUntilSent(.binary(pcm))
        let oldRun = engine.runTask
        engine.cancel()
        newAudio.pair.continuation.yield(pcm)
        engine.start()
        await newSocket.waitUntilSent(.binary(pcm))
        await oldSocket.push(.text(#"{"tokens":[{"text":"stale","is_final":true}],"finished":true}"#))
        await oldRun?.value
        #expect(engine.isRecording)
        #expect(finals.isEmpty)
        engine.finish()
        await newSocket.waitUntilSent(.text(""))
        await newSocket.push(.text(#"{"tokens":[{"text":"new","is_final":true}],"finished":true}"#))
        await engine.runTask?.value
        #expect(finals == ["new"])
        #expect(engine.transcript == "new")
        #expect(newAudio.starts == 1)
    }

    @Test func immediateFinishDuringPreparationCancelsWithoutOpeningMicrophone() async {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        engine.start()
        engine.finish()
        await engine.runTask?.value
        #expect(audio.starts == 0)
        #expect(!engine.isBusy)
    }

    @Test func recordingLimitAutomaticallyDrainsAndSendsEOF() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio, recordingLimit: .zero)
        engine.start()
        await socket.waitUntilSent(.text(""))
        #expect(!engine.isRecording)
        await socket.push(.text(#"{"tokens":[],"finished":true}"#))
        await engine.runTask?.value
        #expect(!engine.isBusy)
    }

    /// Owner request: a recording that recognizes nothing new for the silence limit finishes by itself and keeps
    /// what it heard.
    @Test func recordingFinishesAfterTheSilenceLimitAndKeepsTheText() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        engine.silenceLimit = .milliseconds(300)
        var finals: [String] = []
        engine.onFinal = { finals.append($0) }
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        await socket.push(.text(#"{"tokens":[{"text":"hello","is_final":false}]}"#))
        try await waitUntil { engine.transcript == "hello" }
        await socket.waitUntilSent(.text(""))
        #expect(engine.phase == .finishing)
        await socket.push(.text(#"{"tokens":[{"text":"hello","is_final":true}],"finished":true}"#))
        await engine.runTask?.value
        #expect(finals == ["hello"])
        #expect(engine.finishedForSilence)
    }

    /// The limit counts from the last recognized text, so steady speech is never cut off. Time is the behavior here.
    @Test func newTextKeepsTheSilenceLimitFromFinishing() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        engine.silenceLimit = .seconds(1)
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        for word in 1...8 {
            await socket.push(.text(#"{"tokens":[{"text":"w\#(word)","is_final":false}]}"#))
            try await waitUntil { engine.transcript == "w\(word)" }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(engine.isRecording)
        #expect(!engine.finishedForSilence)
        engine.silenceLimit = nil
        engine.cancel()
    }

    @Test func finalizationTimeoutRetainsTextAndSuppressesCallback() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio, finishTimeout: .zero)
        var finals: [String] = []
        engine.onFinal = { finals.append($0) }
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        await socket.push(.text(#"{"tokens":[{"text":"Retained","is_final":true}]}"#))
        try await waitUntil { engine.transcript == "Retained" }
        engine.finish()
        await engine.runTask?.value
        #expect(!engine.isBusy)
        #expect(engine.transcript == "Retained")
        #expect(finals.isEmpty)
    }

    @Test func emptyCompletionDoesNotPromoteProvisionalSpeech() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        var finals: [String] = []
        engine.onFinal = { finals.append($0) }
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        await socket.push(.text(#"{"tokens":[{"text":"unconfirmed","is_final":false}]}"#))
        try await waitUntil { engine.transcript == "unconfirmed" }
        engine.finish()
        await socket.waitUntilSent(.text(""))
        await socket.push(.text(#"{"finished":true}"#))
        await engine.runTask?.value
        #expect(finals == [""])
    }

    @Test func keyIsStoredOnlyInTheAppsOwnStore() async {
        let own = TestCredentials("own")
        let engine = SpeechEngine(sessionFactory: { SonioxSession() }, audioFactory: { _ in TestAudio() },
                                  credentials: own)
        #expect(await own.loads == 0)
        await engine.loadKey()
        #expect(engine.apiKey == "own")
        engine.apiKey = "replacement"
        await engine.saveKey()
        #expect(await own.value == "replacement")
        #expect(!engine.hasError)
        engine.apiKey = " "
        await engine.saveKey()
        #expect(await own.value == "replacement")
        #expect(engine.keyFailed)
        // A key problem belongs to the key row, not to dictation.
        #expect(!engine.hasError)
    }

    @Test func deletingTheKeyRemovesItFromTheStoreAndTheField() async {
        let own = TestCredentials("own")
        let engine = SpeechEngine(sessionFactory: { SonioxSession() }, audioFactory: { _ in TestAudio() },
                                  credentials: own)
        await engine.loadKey()
        await engine.deleteKey()
        #expect(await own.value == nil)
        #expect(engine.apiKey.isEmpty)
        #expect(!engine.keyFailed)
        #expect(engine.keyActivity == .idle)
    }

    @Test func keyActivityIsVisibleWhileTheStoreWorks() async throws {
        let own = TestCredentials()
        let engine = SpeechEngine(sessionFactory: { SonioxSession() }, audioFactory: { _ in TestAudio() },
                                  credentials: own)
        engine.apiKey = "new"
        await own.holdSave()
        let saving = Task { await engine.saveKey() }
        try await waitUntil { engine.keyActivity == .saving }
        await engine.loadKey()
        #expect(await own.loads == 0)
        await own.releaseSave()
        await saving.value
        #expect(engine.keyActivity == .idle)
        #expect(await own.value == "new")
    }

    @Test func keychainStatusesAreNotReportedAsPermissions() {
        #expect(KeychainCredentialStore.error(for: errSecInteractionNotAllowed) == .keychain(errSecInteractionNotAllowed))
        #expect(KeychainCredentialStore.error(for: errSecUserCanceled) == .keychainDenied)
        #expect(KeychainCredentialStore.error(for: errSecAuthFailed) == .keychainDenied)
    }

    @Test func configurationFailuresAskForSettingsNotARetry() async throws {
        let blank = SpeechEngine(sessionFactory: { SonioxSession(transport: TestSocket()) },
                                 audioFactory: { _ in TestAudio() }, isOffline: { false })
        blank.start()
        #expect(blank.hasError)
        #expect(blank.needsSettings)
        let offline = SpeechEngine(sessionFactory: { SonioxSession(transport: TestSocket()) },
                                   audioFactory: { _ in TestAudio() }, isOffline: { true })
        offline.apiKey = "fixture"
        offline.start()
        #expect(offline.hasError)
        #expect(!offline.needsSettings)
        #expect(SpeechEngine.needsSettings(AppError.microphoneSilent))
        #expect(SpeechEngine.needsSettings(AppError.inputDeviceUnavailable))
        #expect(SpeechEngine.needsSettings(AppError.provider(code: 401, message: "Invalid API key")))
        #expect(!SpeechEngine.needsSettings(AppError.connectionFailed))
        #expect(!SpeechEngine.needsSettings(AppError.provider(code: 503, message: "busy")))
    }

    @Test func selectedMicrophoneIsPassedToCapture() async throws {
        let socket = TestSocket(), audio = TestAudio()
        var requested: [String?] = []
        let engine = SpeechEngine(sessionFactory: { SonioxSession(transport: socket) },
                                  audioFactory: { requested.append($0); return audio })
        engine.apiKey = "fixture"
        engine.inputDeviceUID = "BuiltInMicrophoneDevice"
        engine.start()
        engine.cancel()
        await engine.runTask?.value
        #expect(requested == ["BuiltInMicrophoneDevice"])
    }

    @Test func silentSessionRetainsPreviousTranscript() async throws {
        let firstSocket = TestSocket(), silentSocket = TestSocket()
        let firstAudio = TestAudio(), silentAudio = TestAudio()
        var sessions = [SonioxSession(transport: firstSocket), SonioxSession(transport: silentSocket)]
        var captures = [firstAudio, silentAudio]
        let engine = SpeechEngine(sessionFactory: { sessions.removeFirst() },
                                  audioFactory: { _ in captures.removeFirst() })
        engine.apiKey = "fixture"
        var finals: [String] = []
        engine.onFinal = { finals.append($0) }
        firstAudio.pair.continuation.finish()
        engine.start()
        await firstSocket.waitUntilSent(.text(""))
        await firstSocket.push(.text(#"{"tokens":[{"text":"Saved text","is_final":true}],"finished":true}"#))
        await engine.runTask?.value
        #expect(engine.transcript == "Saved text")
        silentAudio.pair.continuation.finish()
        engine.start()
        await silentSocket.waitUntilSent(.text(""))
        await silentSocket.push(.text(#"{"tokens":[],"finished":true}"#))
        await engine.runTask?.value
        #expect(engine.transcript == "Saved text")
        #expect(finals == ["Saved text", ""])
    }

    @Test func credentialLoadDoesNotOverwriteRecordingStatus() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = SpeechEngine(sessionFactory: { SonioxSession(transport: socket) },
                                  audioFactory: { _ in audio }, credentials: TestCredentials("saved"))
        engine.apiKey = "fixture"
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilSent(.binary(pcm))
        let recordingStatus = engine.status
        await engine.loadKey()
        #expect(engine.status == recordingStatus)
        #expect(engine.isRecording)
        engine.cancel()
        await engine.runTask?.value
    }

    @Test func providerConnectsWhileMicrophoneStarts() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        audio.holdStart()
        audio.pair.continuation.yield(pcm)
        engine.start()
        await socket.waitUntilConnected()
        #expect(engine.phase == .preparing)
        audio.releaseStart()
        await socket.waitUntilSent(.binary(pcm))
        #expect(engine.isRecording)
        engine.cancel()
        await engine.runTask?.value
    }

    @Test func recordingBuffersAudioUntilProviderIsReady() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        await socket.holdConfig()
        audio.pair.continuation.yield(pcm)
        engine.start()
        try await waitUntil { engine.isRecording }
        #expect(await socket.sent.contains(.binary(pcm)) == false)
        await socket.releaseConfig()
        await socket.waitUntilSent(.binary(pcm))
        #expect(!engine.hasError)
        engine.cancel()
        await engine.runTask?.value
    }

    @Test func finishWhileConnectingSendsBufferedAudioThenEOF() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        var finals: [String] = []
        engine.onFinal = { finals.append($0) }
        await socket.holdConfig()
        audio.pair.continuation.yield(pcm)
        engine.start()
        try await waitUntil { engine.isRecording }
        engine.finish()
        #expect(engine.phase == .finishing)
        await socket.releaseConfig()
        await socket.waitUntilSent(.text(""))
        #expect(Array(await socket.sent.suffix(2)) == [.binary(pcm), .text("")])
        await socket.push(.text(#"{"tokens":[{"text":"짧게","is_final":true}],"finished":true}"#))
        await engine.runTask?.value
        #expect(finals == ["짧게"])
        #expect(!engine.hasError)
    }

    @Test func failedConnectionRetriesOnceOnAFreshSession() async throws {
        let dead = TestSocket(), live = TestSocket(), audio = TestAudio()
        await dead.refuseConnection()
        var sessions = [SonioxSession(transport: dead), SonioxSession(transport: live)]
        let engine = SpeechEngine(sessionFactory: { sessions.removeFirst() }, audioFactory: { _ in audio })
        engine.apiKey = "fixture"
        audio.pair.continuation.yield(pcm)
        engine.start()
        await live.waitUntilSent(.binary(pcm))
        #expect(engine.isRecording)
        #expect(!engine.hasError)
        #expect(await dead.closed)
        engine.cancel()
        await engine.runTask?.value
        await live.waitUntilClosed()
    }

    @Test func secondConnectionFailureEndsWithAnError() async throws {
        let first = TestSocket(), second = TestSocket(), audio = TestAudio()
        await first.refuseConnection()
        await second.refuseConnection()
        var sessions = [SonioxSession(transport: first), SonioxSession(transport: second)]
        var created = 0
        let engine = SpeechEngine(sessionFactory: { created += 1; return sessions.removeFirst() },
                                  audioFactory: { _ in audio })
        engine.apiKey = "fixture"
        var finals: [String] = []
        engine.onFinal = { finals.append($0) }
        engine.start()
        await engine.runTask?.value
        #expect(engine.hasError)
        #expect(engine.outcome == .failed)
        #expect(!engine.isBusy)
        #expect(created == 2)
        #expect(finals.isEmpty)
    }

    @Test func microphoneFailureClosesThePendingConnection() async throws {
        let socket = TestSocket(), audio = TestAudio()
        let engine = engine(socket, audio)
        await socket.holdConfig()
        audio.holdStart()
        audio.startError = .microphoneSilent
        engine.start()
        await socket.waitUntilConnected()
        audio.releaseStart()
        await engine.runTask?.value
        #expect(engine.hasError)
        await socket.waitUntilClosed()
    }

    @Test func offlineStartFailsBeforeTouchingMicrophoneOrNetwork() async {
        let socket = TestSocket(), audio = TestAudio()
        let engine = SpeechEngine(sessionFactory: { SonioxSession(transport: socket) },
                                  audioFactory: { _ in audio }, isOffline: { true })
        engine.apiKey = "fixture"
        engine.start()
        #expect(engine.hasError)
        #expect(engine.outcome == .failed)
        #expect(!engine.isBusy)
        #expect(audio.starts == 0)
        #expect(await socket.connections == 0)
    }

    /// The app asks before it hands focus back to the target app, so a refused start leaves Settings in front.
    @Test func startRefusalIsKnownBeforeStarting() {
        let engine = SpeechEngine(sessionFactory: { SonioxSession(transport: TestSocket()) },
                                  audioFactory: { _ in TestAudio() }, isOffline: { false })
        #expect(engine.refusesStart)
        engine.apiKey = "fixture"
        #expect(!engine.refusesStart)
        let offline = SpeechEngine(sessionFactory: { SonioxSession(transport: TestSocket()) },
                                   audioFactory: { _ in TestAudio() }, isOffline: { true })
        offline.apiKey = "fixture"
        #expect(offline.refusesStart)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SonioxTransportTests {
    @Test func stalledHandshakeFailsWithinTheConnectBound() async throws {
        let socket = TestSocket()
        await socket.holdConfig()
        let session = SonioxSession(transport: socket, connectTimeout: .milliseconds(30))
        await #expect(throws: AppError.connectionFailed) { _ = try await session.open(apiKey: "fixture") }
        #expect(await socket.closed)
    }

    @Test func refusedConnectionIsAConnectionFailure() async throws {
        let socket = TestSocket()
        await socket.refuseConnection()
        await #expect(throws: AppError.connectionFailed) { _ = try await SonioxSession(transport: socket).open(apiKey: "fixture") }
    }

    @Test func cancelBeforeOpenNeverConnects() async throws {
        let socket = TestSocket()
        let session = SonioxSession(transport: socket)
        await session.cancel()
        await #expect(throws: AppError.cancelled) { _ = try await session.open(apiKey: "fixture") }
        #expect(await socket.connections == 0)
    }

    @Test func configurationPCMAndTextEOFUseProductionProtocol() async throws {
        let socket = TestSocket()
        let session = SonioxSession(transport: socket)
        let events = try await session.open(apiKey: " fixture ")
        let reader = Task { var result: [TranscriptEvent] = []; for try await e in events { result.append(e) }; return result }
        guard case .text(let text) = await socket.sent.first else {
            Issue.record("Missing configuration"); return
        }
        let config = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        // Soniox refuses a key in the start message from 2027-01-15; it rides on the upgrade request.
        #expect(config["api_key"] == nil)
        #expect(await socket.apiKey == "fixture")
        #expect(config["translation"] == nil)
        #expect(config["audio_format"] as? String == "pcm_s16le")
        #expect(config["sample_rate"] as? Int == 16000)
        #expect(config["model"] as? String == "stt-rt-v5")
        #expect(config["context"] == nil)
        try await session.sendAudio(Data([1, 2]))
        try await session.finish()
        #expect(await socket.sent.suffix(2) == [.binary(Data([1, 2])), .text("")])
        await socket.push(.text(#"{"tokens":[{"text":"final","is_final":true}],"finished":true}"#))
        #expect(try await reader.value == [.status(.configSent),
                                          .update(.init(turnID: "soniox-0", revision: 1, text: "final", isFinal: true,
                                                        spans: [.init(text: "final", startMs: nil)])),
                                          .finished])
        #expect(await socket.closed)
    }

    @Test func blockedEOFSendsAreBounded() async throws {
        let socket = TestSocket()
        let session = SonioxSession(transport: socket, timeout: .milliseconds(30))
        let events = try await session.open(apiKey: "fixture")
        await socket.holdEOF()
        let reader = Task { for try await _ in events {} }
        await #expect(throws: AppError.timeout("Provider send")) { try await session.finish() }
        await #expect(throws: AppError.timeout("Provider send")) { try await reader.value }
        #expect(await socket.closed)
    }

    @Test func blankKeyNeverConnects() async {
        let socket = TestSocket()
        await #expect(throws: AppError.missingCredential(.soniox)) {
            _ = try await SonioxSession(transport: socket).open(apiKey: " ")
        }
        #expect(await socket.connections == 0)
    }
}
