import XCTest
@testable import SPlayerRemote

final class RemoteAPIClientTests: XCTestCase {

    private let baseURL = URL(string: "http://192.168.31.100:6688/api/external")!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func makeClient(token: String = "secret-token") -> RemoteAPIClient {
        RemoteAPIClient(baseURL: baseURL, token: token, session: TestSession.make())
    }

    func testFetchStatusDecodesFixtureAndSendsAuth() async throws {
        var observed: URLRequest?
        MockURLProtocol.setHandler { request in
            observed = request
            return (200, ProtocolFixtures.status)
        }

        let status = try await makeClient().fetchStatus()

        XCTAssertEqual(status.state, .playing)
        XCTAssertEqual(status.position, 12000)
        XCTAssertEqual(status.duration, 240000)
        XCTAssertEqual(status.volume, 0.5, accuracy: 0.0001)
        XCTAssertFalse(status.isFinished)

        let request = try XCTUnwrap(observed)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/external/status")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testFetchNowPlayingIgnoresSrcField() async throws {
        MockURLProtocol.setHandler { _ in (200, ProtocolFixtures.nowPlaying) }
        let now = try await makeClient().fetchNowPlaying()
        XCTAssertEqual(now.songId, 7)
        XCTAssertTrue(now.playing)
        XCTAssertEqual(now.position, 12000)
        // NowPlayingResponse 根本没有 src 属性，无法泄漏到 UI/日志。
    }

    func testUnauthorizedMapsToUnauthorized() async {
        MockURLProtocol.setHandler { _ in (401, Data(#"{"error":"UNAUTHORIZED"}"#.utf8)) }
        await assertError(.unauthorized) { _ = try await self.makeClient().fetchInfo() }
    }

    func testForbiddenMapsToForbidden() async {
        MockURLProtocol.setHandler { _ in (403, Data(#"{"error":"FORBIDDEN"}"#.utf8)) }
        await assertError(.forbidden) { _ = try await self.makeClient().fetchStatus() }
    }

    func testServerErrorMapsToHTTPStatus() async {
        MockURLProtocol.setHandler { _ in (500, Data()) }
        await assertError(.httpStatus(500)) { _ = try await self.makeClient().fetchStatus() }
    }

    func testRedirectStatusIsSurfacedNotFollowed() async {
        // 真实会话由 RedirectDenyingDelegate 拒绝重定向；这里验证 3xx 会被当作错误上报，
        // 而不会被静默跟随到其它主机。
        MockURLProtocol.setHandler { _ in (301, Data()) }
        await assertError(.httpStatus(301)) { _ = try await self.makeClient().fetchInfo() }
    }

    func testInvalidJSONMapsToDecoding() async {
        MockURLProtocol.setHandler { _ in (200, Data("not json".utf8)) }
        await assertError(.decoding) { _ = try await self.makeClient().fetchStatus() }
    }

    func testCancelledErrorMapsToCancelled() async {
        MockURLProtocol.setHandler { _ in throw URLError(.cancelled) }
        await assertError(.cancelled) { _ = try await self.makeClient().fetchStatus() }
    }

    func testNetworkErrorMapsToTransport() async {
        MockURLProtocol.setHandler { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await makeClient().fetchStatus()
            XCTFail("应当抛出错误")
        } catch let error as RemoteAPIError {
            guard case .transport = error else {
                return XCTFail("期望 transport，得到 \(error)")
            }
        } catch {
            XCTFail("未知错误 \(error)")
        }
    }

    func testSeekRejectsNegativePositionLocally() async {
        MockURLProtocol.setHandler { _ in XCTFail("不应发出请求"); return (200, Data()) }
        await assertError(.invalidConfiguration("跳转位置必须大于等于 0。")) {
            try await self.makeClient().seek(positionMs: -1)
        }
    }

    func testSetVolumeRejectsNonFiniteLocally() async {
        MockURLProtocol.setHandler { _ in XCTFail("不应发出请求"); return (200, Data()) }
        do {
            try await makeClient().setVolume(Double.nan)
            XCTFail("应当抛出错误")
        } catch let error as RemoteAPIError {
            guard case .invalidConfiguration = error else {
                return XCTFail("期望 invalidConfiguration，得到 \(error)")
            }
        } catch {
            XCTFail("未知错误 \(error)")
        }
    }

    func testSetVolumeClampsAboveOne() async throws {
        var body: Data?
        MockURLProtocol.setHandler { request in
            body = request.httpBody ?? request.bodyStreamData
            return (200, Data(#"{"ok":true}"#.utf8))
        }
        try await makeClient().setVolume(2.5)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
        XCTAssertEqual(json["volume"] as? Double, 1.0)
    }

    // MARK: - 严格解码 / 校验

    func testStatusDecodeRejectsEmptyOrErrorObject() async {
        MockURLProtocol.setHandler { _ in (200, Data("{}".utf8)) }
        await assertError(.decoding) { _ = try await self.makeClient().fetchStatus() }

        MockURLProtocol.setHandler { _ in (200, Data(#"{"error":"unexpected"}"#.utf8)) }
        await assertError(.decoding) { _ = try await self.makeClient().fetchStatus() }
    }

    func testInfoDecodeRequiresNameAndVersion() async {
        MockURLProtocol.setHandler { _ in (200, Data(#"{"wsClients":1}"#.utf8)) }
        await assertError(.decoding) { _ = try await self.makeClient().fetchInfo() }
    }

    func testNowPlayingDecodeRequiresCoreFields() async {
        MockURLProtocol.setHandler { _ in (200, Data(#"{"songId":7}"#.utf8)) }
        await assertError(.decoding) { _ = try await self.makeClient().fetchNowPlaying() }
    }

    func testStatusRejectsWrongFieldTypes() async {
        MockURLProtocol.setHandler { _ in
            (200, Data(#"{"state":"playing","position":"12000","duration":240000,"volume":0.5,"isFinished":false}"#.utf8))
        }
        await assertError(.decoding) { _ = try await self.makeClient().fetchStatus() }
    }

    func testStatusClampsNegativeTimesAndVolume() async throws {
        MockURLProtocol.setHandler { _ in
            (200, Data(#"{"state":"playing","position":-500,"duration":-1,"volume":2.5,"isFinished":false}"#.utf8))
        }
        let status = try await makeClient().fetchStatus()
        XCTAssertEqual(status.position, 0)
        XCTAssertEqual(status.duration, 0)
        XCTAssertEqual(status.volume, 1.0)
    }

    func testNowPlayingClampsNegativeTimesAndVolume() async throws {
        MockURLProtocol.setHandler { _ in
            (200, Data(#"{"src":"http://x/y","songId":7,"paused":false,"playing":true,"buffering":false,"position":-5,"duration":-5,"volume":9}"#.utf8))
        }
        let now = try await makeClient().fetchNowPlaying()
        XCTAssertEqual(now.position, 0)
        XCTAssertEqual(now.duration, 0)
        XCTAssertEqual(now.volume, 1.0)
        XCTAssertEqual(now.songId, 7)
    }

    func testCommandAckRequiresOkTrue() async throws {
        MockURLProtocol.setHandler { _ in (200, Data(#"{"ok":true}"#.utf8)) }
        try await makeClient().send(command: .play)

        MockURLProtocol.setHandler { _ in (200, Data("{}".utf8)) }
        await assertError(.unexpectedResponse) { try await self.makeClient().send(command: .play) }

        MockURLProtocol.setHandler { _ in (200, Data(#"{"ok":false}"#.utf8)) }
        await assertError(.unexpectedResponse) { try await self.makeClient().send(command: .play) }
    }

    func testControlRequestsRequireAckNotJust2xx() async {
        MockURLProtocol.setHandler { _ in (200, Data("{}".utf8)) }
        await assertError(.unexpectedResponse) { try await self.makeClient().setVolume(0.5) }
        await assertError(.unexpectedResponse) { try await self.makeClient().seek(positionMs: 1000) }
    }

    // MARK: - 局域网分享元数据

    func testFetchLanShareQueueUsesPathAndDecodes() async throws {
        var observed: URLRequest?
        MockURLProtocol.setHandler { request in
            observed = request
            return (200, LanShareFixtures.queueJSON)
        }
        let queue = try await makeClient().fetchLanShareQueue()
        let unwrapped = try XCTUnwrap(queue)
        XCTAssertEqual(unwrapped.revision, 11)
        XCTAssertEqual(unwrapped.trackCount, 3)

        let request = try XCTUnwrap(observed)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/lanShare/getQueue")
        XCTAssertEqual(request.url?.host, "192.168.31.100")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertFalse((request.url?.absoluteString ?? "").contains("secret-token"))
    }

    func testLanShareForbiddenMapsToForbidden() async {
        MockURLProtocol.setHandler { _ in (403, Data(#"{"error":"FORBIDDEN"}"#.utf8)) }
        await assertError(.forbidden) { _ = try await self.makeClient().fetchLanShareQueue() }
    }

    func testLanShareNotReadyReturnsNil() async throws {
        MockURLProtocol.setHandler { _ in (200, LanShareFixtures.queueNotReady) }
        let queue = try await makeClient().fetchLanShareQueue()
        XCTAssertNil(queue)
    }

    func testLanShareResponseOverByteLimitIsRejected() async {
        let oversized = Data(repeating: UInt8(ascii: "a"), count: LanShareLimits.maxLyricResponseBytes + 1)
        MockURLProtocol.setHandler { _ in (200, oversized) }
        await assertError(.responseTooLarge) { _ = try await self.makeClient().fetchLanShareLyric() }
    }

    // MARK: - Helpers

    private func assertError(
        _ expected: RemoteAPIError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ block: () async throws -> Void
    ) async {
        do {
            try await block()
            XCTFail("应当抛出错误", file: file, line: line)
        } catch let error as RemoteAPIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("未知错误 \(error)", file: file, line: line)
        }
    }
}

private extension URLRequest {
    /// URLProtocol 中 `httpBody` 可能为空而数据在 `httpBodyStream` 上。
    var bodyStreamData: Data? {
        guard let stream = httpBodyStream else { return httpBody }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
