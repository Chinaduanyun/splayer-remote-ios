import XCTest
@testable import SPlayerRemote

final class DiscoveryTests: XCTestCase {
    func testArtworkWhitelistAndQueryRewrite() {
        XCTAssertNil(DiscoveryArtwork.sanitize("http://p1.music.126.net/a"))
        XCTAssertNil(DiscoveryArtwork.sanitize("https://p100.music.126.net/a"))
        XCTAssertNil(DiscoveryArtwork.sanitize("https://user@p1.music.126.net/a"))
        XCTAssertNil(DiscoveryArtwork.sanitize("https://p1.music.126.net:443/a"))
        XCTAssertEqual(DiscoveryArtwork.sanitize("https://p1.music.126.net/a?secret=x")?.query, "param=300y300")
    }
    func testCapturedRequestHeadersAndBoundedPageQuery() throws {
        let config = ConnectionConfiguration(baseURL: URL(string: "http://example.test:13962/api/external")!, host: "example.test", port: 13962, token: "synthetic", useWebSocket: false)
        let api = DiscoveryAPIClient(configuration: config)
        let r = try api.request("discovery/playlists/123/tracks", query: [URLQueryItem(name: "offset", value: "100"), URLQueryItem(name: "limit", value: "100")])
        XCTAssertEqual(r.url?.path, "/api/remote/v1/discovery/playlists/123/tracks")
        XCTAssertEqual(r.url?.query, "offset=100&limit=100")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
        XCTAssertNil(r.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(r.httpShouldHandleCookies)
        XCTAssertFalse(r.url!.absoluteString.contains("synthetic"))
    }
    func testSelectionTTLAndIndices() throws {
        let selection = try JSONDecoder().decode(DiscoverySelection.self, from: Data("""
        {"selectionId":"11111111-1111-4111-8111-111111111111","expiresAt":2000,"items":[{"id":"1","title":"Song","artists":[]}],"offset":0,"nextOffset":null,"truncated":false}
        """.utf8))
        XCTAssertTrue(selection.playable(index: 0, now: Date(timeIntervalSince1970: 1)))
        XCTAssertFalse(selection.playable(index: 1, now: Date(timeIntervalSince1970: 1)))
        XCTAssertFalse(selection.playable(index: 0, now: Date(timeIntervalSince1970: 2)))
    }
    func testOldAppFeatureGate() {
        XCTAssertTrue(DiscoveryFailure(status: 404, code: "").message.contains("需增强安卓版"))
        XCTAssertTrue(DiscoveryFailure(status: 503, code: "FOREGROUND_REQUIRED").message.contains("前台"))
    }
    @MainActor
    func testDisconnectedGenerationInvalidation() async {
        let mock = DiscoveryMock()
        let model = DiscoveryViewModel(factory: { _ in mock })
        // Disconnected state exposes no mutable settings or discovery client.
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, tokenStore: InMemoryTokenStore())
        let remote = RemoteViewModel(settings: settings)
        await model.connect(remote: remote)
        XCTAssertNil(model.capabilities)
        XCTAssertEqual(mock.gets, 0)
        model.invalidate()
        XCTAssertNil(model.selection)
    }

    @MainActor
    func testCommandUnknownNeverResubmitsAndSharedGate() async throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, tokenStore: InMemoryTokenStore(stored: "synthetic"))
        settings.host = "example.test"
        settings.portText = "13962"
        let remote = RemoteViewModel(settings: settings, clientFactory: { _, _ in MockRemoteAPI() }, pollIntervalNanoseconds: 60_000_000_000)
        await remote.connect()
        defer { remote.disconnectByUser() }
        let mock = DiscoveryMock()
        mock.enabled = true
        let model = DiscoveryViewModel(factory: { _ in mock }, now: { Date(timeIntervalSince1970: 1) }, sleep: {})
        await model.connect(remote: remote)
        await model.query("discovery/daily-songs")
        XCTAssertEqual(model.selection?.items.count, 1)
        mock.session = "changed"
        await model.play(0, remote: remote)
        XCTAssertEqual(mock.posts, 0)
        XCTAssertNil(model.selection)
        await model.connect(remote: remote)
        await model.query("discovery/daily-songs")
        let lease = remote.acquireDiscoveryCommand()
        XCTAssertNotNil(lease)
        XCTAssertFalse(remote.canControl)
        await model.play(0, remote: remote)
        XCTAssertEqual(mock.posts, 0)
        remote.releaseDiscoveryCommand(try XCTUnwrap(lease))
        await model.play(0, remote: remote)
        XCTAssertEqual(mock.posts, 1)
        XCTAssertTrue(model.message.contains("结果未知"))
        XCTAssertNil(model.selection)
        XCTAssertFalse(model.commandPending)
        XCTAssertNil(remote.discoveryCommandLease)
    }

    @MainActor
    func testPendingBoundTerminalStatesAndLostPOST() async {
        for outcome in ["pending", "executing", "applied", "rejected", "expired", "unknown", "lost"] {
            let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, tokenStore: InMemoryTokenStore(stored: "synthetic"))
            settings.host = "example.test"; settings.portText = "13962"
            let playback = MockRemoteAPI()
            let remote = RemoteViewModel(settings: settings, clientFactory: { _, _ in playback }, pollIntervalNanoseconds: 60_000_000_000)
            await remote.connect()
            let mock = DiscoveryMock(); mock.enabled = true; mock.state = outcome; mock.failPost = outcome == "lost"
            let model = DiscoveryViewModel(factory: { _ in mock }, now: { Date(timeIntervalSince1970: 1) }, sleep: {})
            await model.connect(remote: remote)
            await model.query("discovery/daily-songs")
            // Retained matching old song must not confirm an applied command after refresh failure.
            playback.nowPlayingResult = .failure(URLError(.notConnectedToInternet))
            await model.play(0, remote: remote)
            XCTAssertEqual(mock.posts, 1, outcome)
            XCTAssertEqual(mock.polls, ["pending", "executing"].contains(outcome) ? 20 : 0, outcome)
            if outcome == "applied" { XCTAssertTrue(model.message.contains("尚未确认播放")) }
            XCTAssertNil(remote.discoveryCommandLease)
            remote.disconnectByUser()
        }
    }

    @MainActor
    func testDelayedPreflightBackgroundNeverSubmitsAndReleasesLease() async {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, tokenStore: InMemoryTokenStore(stored: "synthetic"))
        settings.host = "example.test"; settings.portText = "13962"
        let remote = RemoteViewModel(settings: settings, clientFactory: { _, _ in MockRemoteAPI() }, pollIntervalNanoseconds: 60_000_000_000)
        await remote.connect()
        defer { remote.disconnectByUser() }
        let mock = DiscoveryMock(); mock.enabled = true
        let model = DiscoveryViewModel(factory: { _ in mock }, now: { Date(timeIntervalSince1970: 1) }, sleep: {})
        await model.connect(remote: remote); await model.query("discovery/daily-songs")
        mock.preflightDelay = { remote.setScenePhase(.background) }
        await model.play(0, remote: remote)
        XCTAssertEqual(mock.posts, 0)
        XCTAssertNil(remote.discoveryCommandLease)
    }

    @MainActor
    func testDelayedStatusConnectionReplacementNoSuccessOrLeakedLease() async {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, tokenStore: InMemoryTokenStore(stored: "synthetic"))
        settings.host = "example.test"; settings.portText = "13962"
        let remote = RemoteViewModel(settings: settings, clientFactory: { _, _ in MockRemoteAPI() }, pollIntervalNanoseconds: 60_000_000_000)
        await remote.connect()
        defer { remote.disconnectByUser() }
        let mock = DiscoveryMock(); mock.enabled = true; mock.state = "pending"
        let model = DiscoveryViewModel(factory: { _ in mock }, now: { Date(timeIntervalSince1970: 1) }, sleep: {})
        await model.connect(remote: remote); await model.query("discovery/daily-songs")
        mock.statusDelay = { remote.disconnectByUser(); await remote.connect() }
        await model.play(0, remote: remote)
        XCTAssertEqual(mock.posts, 1)
        XCTAssertEqual(mock.polls, 1)
        XCTAssertTrue(model.message.contains("结果未知"))
        XCTAssertNil(remote.discoveryCommandLease)
    }
}

private final class DiscoveryMock: DiscoveryAPI {
    var gets = 0
    var posts = 0
    var enabled = false
    private var id = UUID()
    var state = "unknown"
    var failPost = false
    var polls = 0
    var preflightDelay: (() async -> Void)?
    var statusDelay: (() async -> Void)?
    var session = "session"
    func get<T: Decodable>(_ path: String, query: [URLQueryItem], as: T.Type) async throws -> T {
        gets += 1
        guard enabled else { throw DiscoveryFailure(status: 404, code: "") }
        let json: String
        if path == "capabilities" {
            if let preflightDelay { await preflightDelay() }
            json = """
            {"protocolVersion":1,"serverSessionId":"\(session)","accountState":"signedIn","rendererReady":true,"collabAuthorized":true}
            """
        } else if path.hasPrefix("commands/") {
            polls += 1
            if let statusDelay { await statusDelay() }
            json = "{\"commandId\":\"\(id.uuidString)\",\"state\":\"\(state)\"}"
        } else {
            json = """
            {"selectionId":"11111111-1111-4111-8111-111111111111","expiresAt":200000,"items":[{"id":"42","title":"Song","artists":[]}],"offset":0,"nextOffset":null,"truncated":false}
            """
        }
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
    func submit(session: String, selection: UUID, index: Int, command: UUID) async throws -> DiscoveryCommandStatus {
        posts += 1
        id = command
        if failPost { throw URLError(.networkConnectionLost) }
        let result = state == "applied" ? ",\"result\":{\"queueApplied\":true,\"playbackConfirmed\":false,\"selectedTrackId\":\"42\"}" : ""
        return try JSONDecoder().decode(DiscoveryCommandStatus.self, from: Data("{\"commandId\":\"\(command.uuidString)\",\"state\":\"\(state)\"\(result)}".utf8))
    }
}
