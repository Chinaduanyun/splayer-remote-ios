import Foundation
@testable import SPlayerRemote

// MARK: - 内存 Token 存储

final class InMemoryTokenStore: TokenStoring {
    private(set) var stored: String?
    var saveShouldFail = false

    init(stored: String? = nil) { self.stored = stored }

    func save(token: String) throws {
        if saveShouldFail { throw KeychainError.unexpectedStatus(-1) }
        stored = token
    }

    func loadToken() throws -> String? { stored }
    func deleteToken() throws { stored = nil }
}

// MARK: - Mock 远端 API

final class MockRemoteAPI: RemoteAPI {
    var infoResult: Result<InfoResponse, Error> = .success(InfoResponse(name: "SPlayer Next", version: "9.9.9", wsClients: 1))
    var statusResult: Result<StatusResponse, Error> = .success(StatusResponse(state: .playing, position: 12000, duration: 240000, volume: 0.5, isFinished: false))
    var nowPlayingResult: Result<NowPlayingResponse, Error> = .success(NowPlayingResponse(songId: 42, paused: false, playing: true, buffering: false, position: 12000, duration: 240000, volume: 0.5))
    var commandResult: Result<Void, Error> = .success(())
    var seekResult: Result<Void, Error> = .success(())
    var volumeResult: Result<Void, Error> = .success(())

    /// 可选的异步「挂起」钩子，用于确定性地测试延迟返回 / 取消 / 后台场景。
    var infoDelay: (() async -> Void)?
    var statusDelay: (() async -> Void)?
    var nowPlayingDelay: (() async -> Void)?
    var commandDelay: (() async -> Void)?
    var seekDelay: (() async -> Void)?
    var volumeDelay: (() async -> Void)?

    private(set) var infoCallCount = 0
    private(set) var statusCallCount = 0
    private(set) var nowPlayingCallCount = 0
    private(set) var sentCommands: [RemoteCommand] = []
    private(set) var soughtPositions: [Int] = []
    private(set) var setVolumes: [Double] = []

    func fetchInfo() async throws -> InfoResponse {
        infoCallCount += 1
        if let infoDelay { await infoDelay() }
        return try infoResult.get()
    }

    func fetchStatus() async throws -> StatusResponse {
        statusCallCount += 1
        if let statusDelay { await statusDelay() }
        return try statusResult.get()
    }

    func fetchNowPlaying() async throws -> NowPlayingResponse {
        nowPlayingCallCount += 1
        if let nowPlayingDelay { await nowPlayingDelay() }
        return try nowPlayingResult.get()
    }

    func send(command: RemoteCommand) async throws {
        sentCommands.append(command)
        if let commandDelay { await commandDelay() }
        try commandResult.get()
    }

    func seek(positionMs: Int) async throws {
        soughtPositions.append(positionMs)
        if let seekDelay { await seekDelay() }
        try seekResult.get()
    }

    func setVolume(_ volume: Double) async throws {
        setVolumes.append(volume)
        if let volumeDelay { await volumeDelay() }
        try volumeResult.get()
    }
}

// MARK: - 异步闸门（确定性 hold/release）

/// `wait()` 会挂起直到 `open()` 被调用；`open()` 后可重复通过。
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

// MARK: - Mock 远端 API（可记录请求的 URLProtocol）

final class MockURLProtocol: URLProtocol {
    /// 返回 (HTTP 状态码, 响应体)；抛错则模拟网络错误。
    static var handler: ((URLRequest) throws -> (Int, Data))?
    private static let lock = NSLock()

    static func setHandler(_ handler: ((URLRequest) throws -> (Int, Data))?) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    static func currentHandler() -> ((URLRequest) throws -> (Int, Data))? {
        lock.lock(); defer { lock.unlock() }
        return handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.currentHandler() else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "http://localhost")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Mock WebSocket

/// 确定性 mock socket：可注入消息、模拟远端关闭、记录 start/stop。
final class MockRemoteSocket: RemoteSocket {
    private(set) var state: RemoteSocketState = .idle
    var onMessage: ((RemoteSocketMessage) -> Void)?
    var onStateChange: ((RemoteSocketState) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    /// `start()` 时是否自动进入 open 状态。
    var autoOpen = true

    func start() {
        startCount += 1
        state = .connecting
        onStateChange?(.connecting)
        if autoOpen {
            state = .open
            onStateChange?(.open)
        }
    }

    func stop() {
        stopCount += 1
        state = .closed
    }

    /// 模拟对端主动关闭（会通知状态变化）。
    func simulateRemoteClose() {
        state = .closed
        onStateChange?(.closed)
    }

    /// 注入一条消息。
    func emit(_ message: RemoteSocketMessage) {
        onMessage?(message)
    }
}

/// 记录创建的 socket，便于断言「单连接 / 有界重连」以及重连使用的配置。
final class MockSocketFactory {
    private(set) var sockets: [MockRemoteSocket] = []
    private(set) var requestedBaseURLs: [URL] = []
    private(set) var requestedTokens: [String] = []
    var autoOpen = true
    var configure: ((MockRemoteSocket) -> Void)?

    var latest: MockRemoteSocket? { sockets.last }

    func make() -> RemoteSocketFactory {
        { [weak self] baseURL, token in
            let socket = MockRemoteSocket()
            socket.autoOpen = self?.autoOpen ?? true
            self?.requestedBaseURLs.append(baseURL)
            self?.requestedTokens.append(token)
            self?.configure?(socket)
            self?.sockets.append(socket)
            return socket
        }
    }
}

/// 可控单调时钟，用于确定性验证平滑进度。
final class TestMonotonicClock {
    var now: TimeInterval
    init(now: TimeInterval = 1_000) { self.now = now }
    func advance(_ seconds: TimeInterval) { now += seconds }
}

enum TestSession {
    static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - 测试夹具

enum ProtocolFixtures {
    static let info = Data(#"{"name":"SPlayer Next","version":"1.0.0","wsClients":2}"#.utf8)
    static let status = Data(#"{"state":"playing","position":12000,"duration":240000,"volume":0.5,"isFinished":false}"#.utf8)
    /// 故意包含上游 `src` 字段，验证客户端会忽略它。
    static let nowPlaying = Data(#"{"src":"http://secret.example/media/stream?id=abc","songId":7,"paused":false,"playing":true,"buffering":false,"position":12000,"duration":240000,"volume":0.5}"#.utf8)
}
