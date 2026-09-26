import AVFoundation
import Foundation
import Observation
import Testing
@testable import DictationSpeech

// Adapted from Speech-to-action's FakeSocket; exact event subscriptions replace sleeps.
actor TestSocket: SocketTransport {
    private(set) var sent: [SocketFrame] = []
    private(set) var closed = false
    private(set) var connections = 0
    private var frames: [SocketFrame] = []
    private var receiver: CheckedContinuation<SocketFrame, any Error>?
    private var sentWaiters: [(SocketFrame, CheckedContinuation<Void, Never>)] = []
    private var blockedSend: CheckedContinuation<Void, any Error>?
    private var blockEOF = false

    func connect(url: URL) { connections += 1 }
    func holdEOF() { blockEOF = true }
    func send(_ frame: SocketFrame) async throws {
        guard !closed else { throw AppError.cancelled }
        sent.append(frame)
        let ready = sentWaiters.filter { $0.0 == frame }
        sentWaiters.removeAll { $0.0 == frame }
        for (_, waiter) in ready { waiter.resume() }
        if blockEOF, frame == .text("") {
            try await withCheckedThrowingContinuation { blockedSend = $0 }
        }
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
    }
}

@MainActor final class TestAudio: AudioCapturing {
    let pair = AsyncThrowingStream<Data, Error>.makeStream()
    private(set) var starts = 0
    private(set) var stops = 0
    func start(format: CaptureFormat) async throws -> AsyncThrowingStream<Data, Error> {
        starts += 1
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
    init(_ value: String? = nil) { self.value = value }
    func load(_ kind: CredentialKind) -> String? { loads += 1; return value }
    func save(_ value: String, for kind: CredentialKind) throws {
        guard !value.isEmpty else { throw AppError.missingCredential(kind) }
        saves += 1
        self.value = value
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
        #expect(engine.hasError)
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
}

@Suite(.timeLimit(.minutes(1)))
struct SonioxTransportTests {
    @Test func configurationPCMAndTextEOFUseProductionProtocol() async throws {
        let socket = TestSocket()
        let session = SonioxSession(transport: socket)
        let events = try await session.open(apiKey: " fixture ")
        let reader = Task { var result: [TranscriptEvent] = []; for try await e in events { result.append(e) }; return result }
        guard case .text(let text) = await socket.sent.first else {
            Issue.record("Missing configuration"); return
        }
        let config = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(config["api_key"] as? String == "fixture")
        #expect(config["audio_format"] as? String == "pcm_s16le")
        #expect(config["sample_rate"] as? Int == 16000)
        #expect(config["model"] as? String == "stt-rt-v5")
        try await session.sendAudio(Data([1, 2]))
        try await session.finish()
        #expect(await socket.sent.suffix(2) == [.binary(Data([1, 2])), .text("")])
        await socket.push(.text(#"{"tokens":[{"text":"final","is_final":true}],"finished":true}"#))
        #expect(try await reader.value == [.status(.configSent),
                                          .update(.init(turnID: "soniox-0", revision: 1, text: "final", isFinal: true)),
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
