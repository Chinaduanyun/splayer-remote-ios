import XCTest
@testable import SPlayerRemote

/// V1.2：场景恢复、局域网元数据、Live Activity 集成的确定性行为。
@MainActor
final class V12ViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let suite = "test-v12-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSettings(useWebSocket: Bool = false, token: String = "t") -> SettingsStore {
        let settings = SettingsStore(defaults: makeDefaults(), tokenStore: InMemoryTokenStore(stored: token))
        settings.host = "192.168.31.100"
        settings.portText = "6688"
        settings.useWebSocket = useWebSocket
        return settings
    }

    private func makeViewModel(
        api: MockRemoteAPI,
        settings: SettingsStore? = nil,
        socketFactory: RemoteSocketFactory? = nil,
        useWebSocket: Bool = false,
        liveActivity: LiveActivityPresenting? = nil,
        clock: TestMonotonicClock = TestMonotonicClock()
    ) -> RemoteViewModel {
        RemoteViewModel(
            settings: settings ?? makeSettings(useWebSocket: useWebSocket),
            clientFactory: { _, _ in api },
            pollIntervalNanoseconds: 60_000_000_000,
            socketFactory: socketFactory,
            wsPollIntervalNanoseconds: 60_000_000_000,
            reconnectDelays: [50_000_000],
            metadataRetryInterval: 15,
            liveActivity: liveActivity,
            monotonicNow: { clock.now },
            dateProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func makeQueue(songId: Int, title: String, playIndex: Int = 0) -> LanShareQueue {
        let payload: [String: Any] = [
            "ok": true,
            "revision": 5,
            "data": [
                "playIndex": playIndex,
                "tracks": [
                    LanShareFixtures.track(id: "999", title: "Stale target"),
                    LanShareFixtures.track(id: String(songId), title: title),
                ],
            ],
        ]
        return try! LanShareQueue.decode(from: JSONSerialization.data(withJSONObject: payload))!
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待超时", file: file, line: line)
    }

    private func drain() async {
        for _ in 0..<30 { await Task.yield() }
    }

    // MARK: - 场景恢复

    func testForegroundImmediatelyRefreshesWithoutManualReconnect() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }
        XCTAssertEqual(vm.status?.position, 12_000)

        vm.setSceneActive(false)
        XCTAssertTrue(vm.isStale)

        api.statusResult = .success(StatusResponse(state: .playing, position: 55_555, duration: 240_000, volume: 0.5, isFinished: false))
        api.nowPlayingResult = .success(NowPlayingResponse(songId: 42, paused: false, playing: true, buffering: false, position: 55_555, duration: 240_000, volume: 0.5))

        vm.setSceneActive(true)
        // 不先睡眠 2/5 秒：应在有限等待内立即刷新。
        await waitUntil { vm.status?.position == 55_555 }
        XCTAssertFalse(vm.isStale)
        XCTAssertTrue(vm.canControl)
    }

    func testInactivePreservesHealthySession() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make(), useWebSocket: true)
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }
        let socket = factory.latest

        vm.setScenePhase(.inactive)
        await drain()
        XCTAssertEqual(socket?.stopCount, 0, ".inactive 不得拆除 socket")
        XCTAssertEqual(vm.transport, .live)
        XCTAssertTrue(vm.canControl)

        vm.setScenePhase(.active)
        await drain()
        XCTAssertEqual(factory.sockets.count, 1, "inactive->active 不得新建 socket")
        XCTAssertEqual(socket?.stopCount, 0)
    }

    func testForegroundRestoresSocketWithoutManualReconnect() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make(), useWebSocket: true)
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }
        XCTAssertEqual(factory.sockets.count, 1)

        vm.setSceneActive(false)
        await waitUntil { (factory.sockets.last?.stopCount ?? 0) >= 1 }

        vm.setSceneActive(true)
        await waitUntil { vm.transport == .live }
        XCTAssertEqual(factory.sockets.count, 2, "仅应新建一条替换 socket")
        XCTAssertTrue(vm.connection.isConnected)
    }

    func testForegroundDoesNotRecoverAfterUserDisconnect() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()
        vm.disconnectByUser()
        let infoCalls = api.infoCallCount

        vm.setSceneActive(false)
        vm.setSceneActive(true)
        await drain()

        XCTAssertFalse(vm.connection.isConnected, "主动断开后不得自动恢复")
        XCTAssertEqual(api.infoCallCount, infoCalls, "不得重新发起连接")
    }

    // MARK: - 元数据（局域网分享）

    func testMetadataMatchesBySongIdNotPlayIndex() async {
        let api = MockRemoteAPI()
        api.lanShareQueueResult = .success(makeQueue(songId: 42, title: "Real current"))
        api.lanShareLyricResult = .success(LanShareFixtures.lyric)
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { vm.metadataState == .available }
        XCTAssertEqual(vm.currentTrack?.id, "42")
        XCTAssertEqual(vm.currentTrack?.title, "Real current")
        XCTAssertEqual(vm.lyric?.lines.count, 3)
    }

    func testMetadata403IsGracefulAndKeepsControlsWorking() async {
        let api = MockRemoteAPI()
        api.lanShareQueueResult = .failure(RemoteAPIError.forbidden)
        api.lanShareLyricResult = .failure(RemoteAPIError.forbidden)
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { vm.metadataState == .unavailable }
        XCTAssertNil(vm.queue)
        XCTAssertNotNil(vm.metadataError)
        XCTAssertTrue(vm.canControl, "元数据 403 绝不影响连接与控制")
        XCTAssertEqual(vm.status?.position, 12_000)

        vm.send(.play)
        await waitUntil { !api.sentCommands.isEmpty }
        XCTAssertEqual(api.sentCommands, [.play])
    }

    func testLateMetadataResponseIsDroppedAfterReconnect() async {
        let api = MockRemoteAPI()
        let gate = AsyncGate()
        api.lanShareQueueResult = .success(makeQueue(songId: 42, title: "Late"))
        api.lanShareQueueDelay = { await gate.wait() }
        let vm = makeViewModel(api: api)
        await vm.connect()

        await waitUntil { api.lanShareQueueCallCount >= 1 }
        vm.disconnect()

        await gate.open()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await drain()

        XCTAssertNil(vm.queue, "迟到的元数据响应必须被丢弃")
        XCTAssertEqual(vm.metadataState, .idle)
    }

    // MARK: - Live Activity

    func testLiveActivitySnapshotHasMetadataAndNoCredentials() async {
        let api = MockRemoteAPI()
        api.lanShareQueueResult = .success(makeQueue(songId: 42, title: "Real current"))
        api.lanShareLyricResult = .success(LanShareFixtures.lyric)
        let spy = SpyLiveActivityPresenter()
        let vm = makeViewModel(api: api, liveActivity: spy)
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { spy.snapshots.contains { $0.title == "Real current" } }
        let snapshot = try! XCTUnwrap(spy.snapshots.last { $0.title == "Real current" })
        XCTAssertEqual(snapshot.songId, "42")
        XCTAssertEqual(snapshot.artist, "Example artist")
        XCTAssertTrue(snapshot.connectionAvailable)
    }

    func testDisablingLiveActivityEndsIt() async {
        let api = MockRemoteAPI()
        let spy = SpyLiveActivityPresenter()
        let vm = makeViewModel(api: api, liveActivity: spy)
        await vm.connect()
        defer { vm.disconnect() }

        vm.setLiveActivityEnabled(true)
        XCTAssertTrue(spy.userEnabled)
        vm.setLiveActivityEnabled(false)
        XCTAssertGreaterThanOrEqual(spy.endCount, 1)
    }

    func testUserDisconnectEndsLiveActivity() async {
        let api = MockRemoteAPI()
        let spy = SpyLiveActivityPresenter()
        let vm = makeViewModel(api: api, liveActivity: spy)
        await vm.connect()
        vm.disconnectByUser()
        XCTAssertGreaterThanOrEqual(spy.endCount, 1)
    }
}

/// 记录 Live Activity 快照的测试替身。
final class SpyLiveActivityPresenter: LiveActivityPresenting {
    var areActivitiesEnabled = true
    private(set) var snapshots: [RemoteActivitySnapshot] = []
    private(set) var endCount = 0
    private(set) var userEnabled = false

    func startOrUpdate(_ snapshot: RemoteActivitySnapshot) { snapshots.append(snapshot) }
    func end() { endCount += 1 }
    func setUserEnabled(_ enabled: Bool) { userEnabled = enabled }
}
