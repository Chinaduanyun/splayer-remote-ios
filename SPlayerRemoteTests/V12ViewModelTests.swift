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
        intentSessionStore: RemoteIntentAuthorizedSessionStore? = nil,
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
            intentSessionStore: intentSessionStore,
            monotonicNow: { clock.now },
            dateProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func makeQueue(ids: [Int]) -> LanShareQueue {
        let tracks = ids.map { LanShareFixtures.track(id: String($0), title: "Track \($0)") }
        let payload: [String: Any] = [
            "ok": true,
            "revision": 5,
            "data": ["playIndex": 0, "tracks": tracks],
        ]
        return try! LanShareQueue.decode(from: JSONSerialization.data(withJSONObject: payload))!
    }

    private func makeLyric(_ text: String) -> LanShareLyricDocument {
        LanShareLyricDocument(
            revision: 1,
            source: LanShareLyricSource(source: "netease", format: "lrc", platform: "netease"),
            lines: [LanShareLyricLine(id: 0, timeMs: 1_000, text: text, translation: nil)],
            isSupported: true
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

    // MARK: - Intent 授权会话（F2）

    func testIntentSessionAuthorizedOnlyWhenConnectedAndActivityEnabled() async {
        let api = MockRemoteAPI()
        let store = RemoteIntentAuthorizedSessionStore()
        let settings = makeSettings()
        settings.setLiveActivityEnabled(true)
        let vm = makeViewModel(api: api, settings: settings, intentSessionStore: store)
        await vm.connect()
        defer { vm.disconnect() }
        XCTAssertNotNil(store.current(), "已连接 + 已启用实时活动时应登记意图会话")
    }

    func testIntentSessionNotAuthorizedWhenActivityDisabled() async {
        let api = MockRemoteAPI()
        let store = RemoteIntentAuthorizedSessionStore()
        let vm = makeViewModel(api: api, intentSessionStore: store)
        await vm.connect()
        defer { vm.disconnect() }
        XCTAssertNil(store.current(), "未启用实时活动时不得登记意图会话")
    }

    func testIntentSessionInvalidatedOnUserDisconnect() async {
        let api = MockRemoteAPI()
        let store = RemoteIntentAuthorizedSessionStore()
        let settings = makeSettings()
        settings.setLiveActivityEnabled(true)
        let vm = makeViewModel(api: api, settings: settings, intentSessionStore: store)
        await vm.connect()
        XCTAssertNotNil(store.current())
        vm.disconnectByUser()
        XCTAssertNil(store.current(), "显式断开必须同步失效意图会话")
    }

    func testIntentSessionInvalidatedOnDisable() async {
        let api = MockRemoteAPI()
        let store = RemoteIntentAuthorizedSessionStore()
        let settings = makeSettings()
        settings.setLiveActivityEnabled(true)
        let vm = makeViewModel(api: api, settings: settings, intentSessionStore: store)
        await vm.connect()
        defer { vm.disconnect() }
        XCTAssertNotNil(store.current())
        vm.setLiveActivityEnabled(false)
        XCTAssertNil(store.current(), "关闭实时活动必须同步失效意图会话")
    }

    func testIntentSessionInvalidatedOnFatalAuthenticationFailure() async {
        let api = MockRemoteAPI()
        let store = RemoteIntentAuthorizedSessionStore()
        let settings = makeSettings()
        settings.setLiveActivityEnabled(true)
        let vm = makeViewModel(api: api, settings: settings, intentSessionStore: store)
        await vm.connect()
        XCTAssertNotNil(store.current())

        api.statusResult = .failure(RemoteAPIError.unauthorized)
        api.nowPlayingResult = .failure(RemoteAPIError.unauthorized)
        await vm.refreshNow()
        XCTAssertNil(store.current(), "致命鉴权失败必须失效意图会话")
    }

    func testIntentSessionInvalidatedOnReplacementWithFailedAuth() async {
        let api = MockRemoteAPI()
        let store = RemoteIntentAuthorizedSessionStore()
        let settings = makeSettings()
        settings.setLiveActivityEnabled(true)
        let vm = makeViewModel(api: api, settings: settings, intentSessionStore: store)
        await vm.connect()
        XCTAssertNotNil(store.current())

        // 替换到 B，但 B 鉴权失败：旧 A 的会话必须先失效。
        settings.host = "10.0.0.9"
        api.infoResult = .failure(RemoteAPIError.unauthorized)
        await vm.connect()
        XCTAssertNil(store.current())

        #if canImport(ActivityKit)
        let before = api.sentCommands.count
        let feedback = RecordingIntentFeedback()
        do {
            try await RemoteIntentCommandExecutor.execute(
                rawCommand: "next",
                sessionStore: store,
                clientFactory: { _, _ in api },
                feedback: feedback
            )
            XCTFail("无授权会话时不应成功")
        } catch {
            // expected
        }
        XCTAssertEqual(api.sentCommands.count, before, "无授权会话时不得发送任何命令")
        XCTAssertTrue(feedback.applied.isEmpty)
        #endif
    }

    // MARK: - 元数据曲目门控 / 合幷（F3）

    func testLyricFromPreviousTrackIsDiscardedAndRefreshQueued() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        api.lanShareQueueResult = .success(makeQueue(ids: [42, 8]))
        api.lanShareLyricResults = [.success(makeLyric("A line")), .success(makeLyric("B line"))]
        let gate = AsyncGate()
        api.lanShareLyricDelay = { await gate.wait() }

        let vm = makeViewModel(api: api, socketFactory: factory.make(), useWebSocket: true)
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }
        await waitUntil { api.lanShareQueueCallCount >= 1 && api.lanShareLyricCallCount >= 1 }

        // A 的歌词请求仍挂起时切到 B。
        factory.latest?.emit(.stateChanged(StateChangedPayload(songId: 8, playing: true, positionMs: 0)))
        await waitUntil { vm.songId == 8 }
        XCTAssertNil(vm.lyric, "曲目切换应立即清空旧歌词")

        await gate.open()
        await waitUntil { vm.lyric?.lines.first?.text == "B line" }
        XCTAssertEqual(vm.currentTrack?.id, "8")
        XCTAssertEqual(vm.lyric?.lines.first?.text, "B line", "迟到的 A 歌词不得覆盖 B")
    }

    func testSuccessfulMetadataBecomesUnavailableAndClearsStalePresentation() async {
        let api = MockRemoteAPI()
        api.lanShareQueueResult = .success(makeQueue(songId: 42, title: "Current"))
        api.lanShareLyricResult = .success(makeLyric("A line"))
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { vm.metadataState == .available && vm.currentTrack != nil }
        XCTAssertNotNil(vm.queue)

        api.lanShareQueueResult = .failure(RemoteAPIError.forbidden)
        api.lanShareLyricResult = .failure(RemoteAPIError.forbidden)
        vm.refreshMetadata(force: true)
        await waitUntil { vm.metadataState == .unavailable }

        XCTAssertNil(vm.queue, "失败后不得保留过期队列冒充当前")
        XCTAssertNil(vm.currentTrack)
        XCTAssertNil(vm.lyric)
        XCTAssertEqual(vm.metadataState, .unavailable)
        XCTAssertNotNil(vm.metadataError)
        XCTAssertTrue(vm.canControl)
    }

    func testMetadataRecoversAfterBackgroundInterruption() async {
        let api = MockRemoteAPI()
        api.lanShareQueueResult = .success(makeQueue(songId: 42, title: "Current"))
        api.lanShareLyricResult = .success(makeLyric("A line"))
        let gate = AsyncGate()
        api.lanShareQueueDelay = { await gate.wait() }

        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { api.lanShareQueueCallCount >= 1 }

        vm.setSceneActive(false)
        vm.setSceneActive(true)
        await gate.open()

        await waitUntil { vm.metadataState == .available && vm.currentTrack?.title == "Current" }
    }

    func testMultipleTrackChangesDuringFetchCoalesceToOneQueuedRefresh() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        api.lanShareQueueResult = .success(makeQueue(ids: [42, 8, 9]))
        api.lanShareLyricResults = [.success(makeLyric("A line")), .success(makeLyric("B line"))]
        let gate = AsyncGate()
        api.lanShareLyricDelay = { await gate.wait() }

        let vm = makeViewModel(api: api, socketFactory: factory.make(), useWebSocket: true)
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }
        await waitUntil { api.lanShareLyricCallCount >= 1 }

        factory.latest?.emit(.stateChanged(StateChangedPayload(songId: 8, playing: true, positionMs: 0)))
        await waitUntil { vm.songId == 8 }
        factory.latest?.emit(.stateChanged(StateChangedPayload(songId: 9, playing: true, positionMs: 0)))
        await waitUntil { vm.songId == 9 }

        await gate.open()
        await waitUntil { vm.lyric?.lines.first?.text == "B line" }
        XCTAssertEqual(vm.currentTrack?.id, "9")
        XCTAssertEqual(api.lanShareLyricCallCount, 2, "多次曲目变化应合并为一次后续刷新")
    }

    func testMetadataNotReadyClearsPresentationAndMarksUnavailable() async {
        let api = MockRemoteAPI()
        api.lanShareQueueResult = .success(makeQueue(songId: 42, title: "Current"))
        api.lanShareLyricResult = .success(makeLyric("A line"))
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { vm.metadataState == .available && vm.currentTrack != nil }

        api.lanShareQueueResult = .success(nil)
        api.lanShareLyricResult = .success(nil)
        vm.refreshMetadata(force: true)
        await waitUntil { vm.metadataState == .unavailable }

        XCTAssertNil(vm.queue, "ok:false 时不得保留过期队列")
        XCTAssertNil(vm.currentTrack)
        XCTAssertEqual(vm.metadataState, .unavailable)
    }

    func testEndedNotifiesActivityAsNotPlayingWithoutNewTimestamp() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let spy = SpyLiveActivityPresenter()
        let vm = makeViewModel(api: api, socketFactory: factory.make(), useWebSocket: true, liveActivity: spy)
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }

        factory.latest?.emit(.ended)
        await waitUntil { spy.snapshots.last?.isPlaying == false }
        XCTAssertEqual(spy.snapshots.last?.timestamp, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - 致命鉴权失败锁存（F8）

    func testAuthenticationFailureLatchesAutomaticReconnectUntilExplicitConnect() async {
        let api = MockRemoteAPI()
        let settings = makeSettings()
        settings.autoConnect = true
        api.infoResult = .failure(RemoteAPIError.unauthorized)
        let vm = makeViewModel(api: api, settings: settings)

        await vm.connectIfConfigured()
        XCTAssertFalse(vm.connection.isConnected)
        let attemptsAfterFailure = api.infoCallCount

        // 后台 / 回前台不得自动重试刚失败的鉴权。
        vm.setSceneActive(false)
        vm.setSceneActive(true)
        await vm.connectIfConfigured()
        XCTAssertEqual(api.infoCallCount, attemptsAfterFailure, "鉴权失败后不得自动重试")

        // 显式连接清除锁存。
        api.infoResult = .success(InfoResponse(name: "SPlayer Next", version: "9.9.9", wsClients: 1))
        await vm.connect()
        XCTAssertTrue(vm.connection.isConnected)
        vm.disconnect()

        let beforeAuto = api.infoCallCount
        await vm.connectIfConfigured()
        XCTAssertGreaterThan(api.infoCallCount, beforeAuto, "显式连接成功后应恢复自动重连能力")
        vm.disconnect()
    }
}

/// 记录反馈调用的测试替身。
final class RecordingIntentFeedback: RemoteIntentFeedbackApplying {
    struct Call {
        let sessionId: UUID
        let status: StatusResponse?
        let nowPlaying: NowPlayingResponse?
        let track: LanShareTrack?
        let authoritativeDate: Date?
    }

    private(set) var applied: [Call] = []
    private let lock = NSLock()

    func apply(
        sessionId: UUID,
        status: StatusResponse?,
        nowPlaying: NowPlayingResponse?,
        track: LanShareTrack?,
        authoritativeDate: Date?
    ) async {
        lock.lock()
        applied.append(Call(sessionId: sessionId, status: status, nowPlaying: nowPlaying, track: track, authoritativeDate: authoritativeDate))
        lock.unlock()
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
