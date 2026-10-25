import XCTest
@testable import SPlayerRemote

final class DiscoveryTransportTests: XCTestCase {
    override func tearDown() { MockURLProtocol.setHandler(nil); super.tearDown() }
    // URLSession may expose a POST body to URLProtocol as a stream rather than Data.
    private static func bodyData(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    private func api() -> DiscoveryAPIClient {
        DiscoveryAPIClient(configuration: ConnectionConfiguration(baseURL: URL(string: "http://example.test:13962/api/external")!, host: "example.test", port: 13962, token: "synthetic", useWebSocket: false), session: TestSession.make())
    }
    func testHTTP404AndMalformedEnvelopes() async {
        for (status, body) in [(404, "not json"), (200, "{\"ok\":true}"), (200, "{\"ok\":false,\"data\":{}}"), (200, "[]")] {
            MockURLProtocol.setHandler { _ in (status, Data(body.utf8)) }
            do {
                let _: DiscoveryCapabilities = try await api().get("capabilities", as: DiscoveryCapabilities.self)
                XCTFail("Invalid envelope accepted")
            } catch {
                if status == 404 { XCTAssertTrue((error as? DiscoveryFailure)?.message.contains("需增强安卓版") == true) }
            }
        }
    }
    func testCommand202ExactBodyAndStatusQuery() async throws {
        let command = UUID(), selection = UUID()
        var posts = 0
        MockURLProtocol.setHandler { r in
            XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            XCTAssertNil(r.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(r.httpShouldHandleCookies)
            XCTAssertFalse(r.url!.absoluteString.contains("synthetic"))
            if r.httpMethod == "POST" {
                posts += 1
                let data = try Self.bodyData(r)
                XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Length"), String(data.count))
                XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(Set(body.keys), Set(["commandId", "serverSessionId", "action", "selectionId", "startIndex"]))
                XCTAssertEqual(body["commandId"] as? String, command.uuidString)
                XCTAssertEqual(body["selectionId"] as? String, selection.uuidString)
                XCTAssertEqual(body["startIndex"] as? Int, 2)
                XCTAssertEqual(body["action"] as? String, "replaceQueue")
                XCTAssertEqual(body["serverSessionId"] as? String, "session")
            } else {
                XCTAssertEqual(r.url?.query, "serverSessionId=session")
                XCTAssertEqual(r.url?.lastPathComponent, command.uuidString)
            }
            return (202, Data("{\"ok\":true,\"data\":{\"commandId\":\"\(command.uuidString)\",\"state\":\"pending\"}}".utf8))
        }
        let client = api()
        let pending = try await client.submit(session: "session", selection: selection, index: 2, command: command)
        XCTAssertEqual(pending.state, "pending")
        let _: DiscoveryCommandStatus = try await client.get("commands/\(command.uuidString)", query: [URLQueryItem(name: "serverSessionId", value: "session")], as: DiscoveryCommandStatus.self)
        XCTAssertEqual(posts, 1)
    }
    @MainActor
    func test404FeatureGateLeavesOriginalRemoteControlsUsable() async {
        MockURLProtocol.setHandler { _ in (404, Data()) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, tokenStore: InMemoryTokenStore(stored: "synthetic"))
        settings.host = "example.test"; settings.portText = "13962"
        let remote = RemoteViewModel(settings: settings, clientFactory: { _, _ in MockRemoteAPI() }, pollIntervalNanoseconds: 60_000_000_000)
        await remote.connect()
        defer { remote.disconnectByUser() }
        let client = api()
        let model = DiscoveryViewModel(factory: { _ in client })
        await model.connect(remote: remote)
        XCTAssertTrue(model.message.contains("需增强安卓版"))
        XCTAssertTrue(remote.canControl)
    }
    @MainActor
    func testTransportPendingPollsTwentyTimesWithoutResubmitting() async {
        var posts = 0, polls = 0
        var command = ""
        MockURLProtocol.setHandler { request in
            let path = request.url!.path
            let value: String
            if path.hasSuffix("capabilities") {
                value = "{\"protocolVersion\":1,\"serverSessionId\":\"session\",\"accountState\":\"signedIn\",\"rendererReady\":true,\"collabAuthorized\":true}"
            } else if path.hasSuffix("daily-songs") {
                value = "{\"selectionId\":\"11111111-1111-4111-8111-111111111111\",\"expiresAt\":200000,\"items\":[{\"id\":\"42\",\"title\":\"Song\",\"artists\":[]}],\"offset\":0,\"nextOffset\":null,\"truncated\":false}"
            } else {
                if request.httpMethod == "POST" {
                    posts += 1
                    let body = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
                    command = body["commandId"] as! String
                } else {
                    polls += 1
                    XCTAssertEqual(request.url?.lastPathComponent, command)
                    XCTAssertEqual(request.url?.query, "serverSessionId=session")
                }
                value = "{\"commandId\":\"\(command)\",\"state\":\"pending\"}"
            }
            return (path.contains("/commands") ? 202 : 200, Data("{\"ok\":true,\"data\":\(value)}".utf8))
        }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, tokenStore: InMemoryTokenStore(stored: "synthetic"))
        settings.host = "example.test"; settings.portText = "13962"
        let remote = RemoteViewModel(settings: settings, clientFactory: { _, _ in MockRemoteAPI() }, pollIntervalNanoseconds: 60_000_000_000)
        await remote.connect()
        defer { remote.disconnectByUser() }
        let client = api()
        let model = DiscoveryViewModel(factory: { _ in client }, now: { Date(timeIntervalSince1970: 1) }, sleep: {})
        await model.connect(remote: remote)
        await model.query("discovery/daily-songs")
        await model.play(0, remote: remote)
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(polls, 20)
        XCTAssertTrue(model.message.contains("结果未知"))
        XCTAssertNil(remote.discoveryCommandLease)
    }
    func testPOSTTransportFailureHasExactlyOneAttempt() async {
        var posts = 0
        MockURLProtocol.setHandler { _ in posts += 1; throw URLError(.networkConnectionLost) }
        do { _ = try await api().submit(session: "session", selection: UUID(), index: 0, command: UUID()); XCTFail("Expected transport failure") }
        catch { XCTAssertEqual(posts, 1) }
    }
    func testDeclaredOversizeRejected() async {
        MockURLProtocol.setHandler { _ in (200, Data(repeating: 32, count: 512 * 1024 + 1)) }
        do { let _: DiscoveryCapabilities = try await api().get("capabilities", as: DiscoveryCapabilities.self); XCTFail("Oversized response accepted") }
        catch { XCTAssertEqual((error as? DiscoveryFailure)?.status, 413) }
    }
    func testStreamOverflowWithoutLength() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiscoveryOverflowProtocol.self]
        let client = DiscoveryAPIClient(configuration: ConnectionConfiguration(baseURL: URL(string: "http://example.test/api/external")!, host: "example.test", port: 80, token: "synthetic", useWebSocket: false), session: URLSession(configuration: config))
        do { let _: DiscoveryCapabilities = try await client.get("capabilities", as: DiscoveryCapabilities.self); XCTFail("Stream overflow accepted") }
        catch { XCTAssertEqual((error as? DiscoveryFailure)?.status, 413) }
    }
}
private final class DiscoveryOverflowProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for _ in 0..<129 { client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 4096)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
