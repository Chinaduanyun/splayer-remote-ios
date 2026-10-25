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

    private(set) var sentCommands: [RemoteCommand] = []
    private(set) var soughtPositions: [Int] = []
    private(set) var setVolumes: [Double] = []

    func fetchInfo() async throws -> InfoResponse { try infoResult.get() }
    func fetchStatus() async throws -> StatusResponse { try statusResult.get() }
    func fetchNowPlaying() async throws -> NowPlayingResponse { try nowPlayingResult.get() }

    func send(command: RemoteCommand) async throws {
        sentCommands.append(command)
        try commandResult.get()
    }

    func seek(positionMs: Int) async throws {
        soughtPositions.append(positionMs)
        try seekResult.get()
    }

    func setVolume(_ volume: Double) async throws {
        setVolumes.append(volume)
        try volumeResult.get()
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
