import Foundation

// Transport and Soniox configuration adapted from Speech-to-action/ProviderSessions.swift.
enum SocketFrame: Sendable, Equatable { case text(String), binary(Data), closed(Int) }
protocol SocketTransport: Sendable {
    func connect(url: URL) async throws
    func send(_ frame: SocketFrame) async throws
    func receive() async throws -> SocketFrame
    func close() async
}
actor URLSocketTransport: SocketTransport {
    private var socket: URLSessionWebSocketTask?
    func connect(url: URL) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
    }
    func send(_ frame: SocketFrame) async throws {
        guard let socket else { throw AppError.cancelled }
        switch frame {
        case .text(let text): try await socket.send(.string(text))
        case .binary(let data): try await socket.send(.data(data))
        case .closed: throw AppError.cancelled
        }
    }
    func receive() async throws -> SocketFrame {
        guard let socket else { throw AppError.cancelled }
        do {
            switch try await socket.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default: throw AppError.invalidResponse("WebSocket frame")
            }
        } catch {
            if socket.closeCode != .invalid { return .closed(socket.closeCode.rawValue) }
            throw AppError.invalidResponse("WebSocket receive")
        }
    }
    func close() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }
}

actor SonioxSession: STTSession {
    private let socket: any SocketTransport
    private let timeout: Duration
    private let connectTimeout: Duration
    private var continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var receiver: Task<Void, Never>?
    private var reducer = SonioxTranscriptReducer()
    private var used = false
    private var active = false
    private var finishing = false
    private var failure: AppError?

    /// `connectTimeout` bounds the handshake plus configuration send. The microphone is already
    /// recording by then, so a dead network must surface within seconds rather than the socket's 10.
    init(transport: any SocketTransport = URLSocketTransport(), timeout: Duration = .seconds(10),
         connectTimeout: Duration = .seconds(3)) {
        socket = transport
        self.timeout = timeout
        self.connectTimeout = connectTimeout
    }

    func open(apiKey: String) async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppError.missingCredential(.soniox) }
        guard !used else { throw failure ?? AppError.invalidResponse("Session already used") }
        used = true
        active = true
        let pair = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        continuation = pair.continuation
        continuation?.onTermination = { [weak self] _ in Task { await self?.cancel() } }
        do {
            try await socket.connect(url: URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!)
            guard active else { throw failure ?? .cancelled }
            let config: [String: Any] = [
                "api_key": key, "model": "stt-rt-v5", "audio_format": "pcm_s16le",
                "sample_rate": 16000, "num_channels": 1, "language_hints": ["ko", "en"],
                "enable_endpoint_detection": true, "endpoint_latency_adjustment_level": 2,
                "endpoint_sensitivity": 0.3, "max_endpoint_delay_ms": 1500
            ]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
            try await sendWithTimeout(.text(text), limit: connectTimeout)
            continuation?.yield(.status(.configSent))
            receiver = Task { [weak self] in await self?.readLoop() }
            return pair.stream
        } catch {
            await terminate(error: failure ?? (error as? AppError) ?? .invalidResponse("Provider connection"))
            let reason = failure ?? .cancelled
            throw reason == .cancelled ? reason : AppError.connectionFailed
        }
    }

    private func readLoop() async {
        do {
            while active {
                let frame = try await socket.receive()
                guard active else { return }
                let events: [TranscriptEvent]
                switch frame {
                case .text(let text): events = try reducer.reduce(Data(text.utf8))
                case .binary(let data): events = try reducer.reduce(data)
                case .closed: throw AppError.invalidResponse("Unexpected provider close")
                }
                if events.contains(.finished), !finishing {
                    throw AppError.invalidResponse("Provider completed before audio EOF")
                }
                for event in events { continuation?.yield(event) }
                if events.contains(.finished) {
                    await terminate(error: nil)
                    return
                }
            }
        } catch {
            await terminate(error: (error as? AppError) ?? .invalidResponse("Provider receive"))
        }
    }

    // One ordered producer drains audio and then calls finish; no polling or parallel sends.
    func sendAudio(_ pcm: Data) async throws {
        guard active, !finishing, !pcm.isEmpty else { throw failure ?? .cancelled }
        try await sendWithTimeout(.binary(pcm))
    }

    func finish() async throws {
        guard active else { throw failure ?? .cancelled }
        guard !finishing else { return }
        finishing = true
        // Soniox's official EOF is an empty TEXT frame, not zero-length binary PCM.
        try await sendWithTimeout(.text(""))
    }

    private func sendWithTimeout(_ frame: SocketFrame, limit: Duration? = nil) async throws {
        let timer = Task { [weak self, timeout] in
            do { try await Task.sleep(for: limit ?? timeout) } catch { return }
            await self?.terminate(error: .timeout("Provider send"))
        }
        defer { timer.cancel() }
        do {
            try await socket.send(frame)
            if let failure { throw failure }
        } catch {
            await terminate(error: failure ?? (error as? AppError) ?? .invalidResponse("Provider send"))
            throw failure ?? .cancelled
        }
    }

    func cancel() async {
        // A session cancelled before it opened must never connect afterwards.
        if !used {
            used = true
            failure = .cancelled
        }
        await terminate(error: .cancelled)
    }

    private func terminate(error: AppError?) async {
        guard active else { return }
        active = false
        failure = error
        receiver?.cancel()
        continuation?.finish(throwing: error)
        continuation = nil
        await socket.close()
    }
}
