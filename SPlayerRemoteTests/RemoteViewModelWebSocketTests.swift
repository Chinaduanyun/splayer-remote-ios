import XCTest
@testable import SPlayerRemote

/// WebSocket 生命周期、回退、进度平滑与快捷操作（全部为确定性 mock）。
@MainActor
final class RemoteViewModelWebSocketTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "test-ws-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSettings(useWebSocket: Bool, token: String = "t") -> SettingsStore {
        let settings = SettingsStore(defaults: makeDefaults(), tokenStore: InMemoryTokenStore(stored: token))
        settings.host = "192.168.31.100"
        settings.portText = "6688"
        settings.useWebSocket = useWebSocket
        return settings
    }

    private func makeViewModel(
        api: MockRemoteAPI,
        settings: SettingsStore? = nil,
        socketFactory: RemoteSocketFactory?,
        useWebSocket: Bool = true,
        clientFactory: ((URL, String) -> RemoteAPI)? = nil,
        clock: TestMonotonicClock = TestMonotonicClock(),
        reconnectDelays: [UInt64] = [50_000_000]
    ) -> RemoteViewModel {
        RemoteViewModel(
            settings: settings ?? makeSettings(useWebSocket: useWebSocket),
            clientFactory: clientFactory ?? { _, _ in api },
            pollIntervalNanoseconds: 60_000_000_000,
            socketFactory: socketFactory,
            wsPollIntervalNanoseconds: 60_000_000_000,
            reconnectDelays: reconnectDelays,
            monotonicNow: { clock.now },
            dateProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    // MARK: - 实时通道

    func testWebSocketConnectsAndAppliesStateChanged() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { factory.latest?.state == .open }
        await waitUntil { vm.transport == .live }
        XCTAssertEqual(factory.sockets.count, 1, "单连接")

        factory.latest?.emit(.hello(clients: 3))
        await waitUntil { vm.wsClientCount == 3 }

        factory.latest?.emit(.stateChanged(StateChangedPayload(
            songId: 7, paused: false, playing: true, buffering: false,
            durationMs: 240_000, positionMs: 30_000, volume: 0.8, playbackRate: 1.5
        )))
        await waitUntil { vm.status?.position == 30_000 }

        XCTAssertEqual(vm.songId, 7)
        XCTAssertEqual(vm.currentVolume, 0.8, accuracy: 0.0001)
        XCTAssertEqual(vm.playbackRate, 1.5, accuracy: 0.0001)
        XCTAssertEqual(vm.playbackState, .playing)
        XCTAssertEqual(vm.transport, .live)
        XCTAssertFalse(vm.isStale)
        XCTAssertNotNil(vm.lastSuccessfulUpdate)
    }

    func testUnknownAckAndErrorMessagesAreIgnored() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }

        let before = vm.status?.position
        factory.latest?.emit(.ack(op: "play"))
        factory.latest?.emit(.error(op: "seek", message: "bad"))
        factory.latest?.emit(.unknown)
        await drain()

        XCTAssertEqual(vm.status?.position, before)
        XCTAssertTrue(vm.connection.isConnected)
        XCTAssertEqual(vm.transport, .live)
        XCTAssertNil(vm.lastError)
    }

    func testWebSocketCloseFallsBackAndReconnectsWithoutDroppingRest() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }

        factory.latest?.simulateRemoteClose()
        await waitUntil { vm.transport == .fallback }
        XCTAssertTrue(vm.connection.isConnected, "WS 断开不等于 REST 断开")
        XCTAssertTrue(vm.canControl)

        // 有界退避后自动重连，且始终保持单连接。
        await waitUntil { factory.sockets.count >= 2 }
        await waitUntil { vm.transport == .live }
        XCTAssertEqual(factory.sockets.count, 2)
    }

    func testTransportDisabledWhenPreferenceOff() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make(), useWebSocket: false)
        await vm.connect()
        defer { vm.disconnect() }

        XCTAssertEqual(vm.transport, .disabled)
        XCTAssertTrue(factory.sockets.isEmpty, "关闭偏好时不得创建 socket")
        XCTAssertTrue(vm.connection.isConnected)
    }

    func testBackgroundStopsSocketAndLateMessageIgnored() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }
        let socket = factory.latest
        let originalPosition = vm.status?.position

        vm.setSceneActive(false)
        await waitUntil { socket?.stopCount ?? 0 >= 1 }
        XCTAssertFalse(vm.canControl)

        // 后台期间的迟到消息必须被丢弃。
        socket?.emit(.stateChanged(StateChangedPayload(positionMs: 999_999)))
        await drain()
        XCTAssertEqual(vm.status?.position, originalPosition)
    }

    func testLateMessageAfterDisconnectIgnored() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        await waitUntil { vm.transport == .live }
        let socket = factory.latest

        vm.disconnect()
        socket?.emit(.stateChanged(StateChangedPayload(songId: 99, playing: true, positionMs: 1234)))
        await drain()

        XCTAssertNil(vm.status)
        XCTAssertNil(vm.nowPlaying)
        guard case .disconnected = vm.connection else {
            return XCTFail("应保持断态，实际 \(vm.connection)")
        }
    }

    func testPollStartedBeforeWebSocketSnapshotIsDiscarded() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }

        let gate = AsyncGate()
        api.statusDelay = { await gate.wait() }
        api.nowPlayingDelay = { await gate.wait() }

        let refresh = Task { await vm.refreshNow() }
        await waitUntil { api.statusCallCount >= 2 }

        // 更“新”的 WS 快照先到达。
        factory.latest?.emit(.stateChanged(StateChangedPayload(positionMs: 55_000)))
        await waitUntil { vm.status?.position == 55_000 }

        await gate.open()
        await refresh.value

        // 较早发起的轮询结果（12000）必须被丢弃，不能覆盖 WS 快照。
        XCTAssertEqual(vm.status?.position, 55_000)
    }

    func testCommandsStillUseHTTPWhenSocketLive() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }

        vm.send(.play)
        await waitUntil { !api.sentCommands.isEmpty }
        XCTAssertEqual(api.sentCommands, [.play])
    }

    // MARK: - 平滑进度

    func testProgressAdvancesOnlyWhenPlaying() async {
        let api = MockRemoteAPI()
        let clock = TestMonotonicClock()
        let vm = makeViewModel(api: api, socketFactory: nil, useWebSocket: false, clock: clock)
        await vm.connect()
        defer { vm.disconnect() }

        XCTAssertEqual(vm.currentPositionMs, 12_000)
        clock.advance(2)
        XCTAssertEqual(vm.currentPositionMs, 14_000)
        clock.advance(1_000)
        XCTAssertEqual(vm.currentPositionMs, 240_000, "不得越过时长")
    }

    func testProgressFrozenWhenPaused() async {
        let api = MockRemoteAPI()
        api.statusResult = .success(StatusResponse(state: .paused, position: 12_000, duration: 240_000, volume: 0.5, isFinished: false))
        api.nowPlayingResult = .success(NowPlayingResponse(songId: 42, paused: true, playing: false, buffering: false, position: 12_000, duration: 240_000, volume: 0.5))
        let clock = TestMonotonicClock()
        let vm = makeViewModel(api: api, socketFactory: nil, useWebSocket: false, clock: clock)
        await vm.connect()
        defer { vm.disconnect() }

        clock.advance(30)
        XCTAssertEqual(vm.currentPositionMs, 12_000)
    }

    func testProgressFrozenWhenStale() async {
        let api = MockRemoteAPI()
        let clock = TestMonotonicClock()
        let vm = makeViewModel(api: api, socketFactory: nil, useWebSocket: false, clock: clock)
        await vm.connect()
        defer { vm.disconnect() }

        clock.advance(1)
        XCTAssertEqual(vm.currentPositionMs, 13_000)

        api.statusResult = .failure(RemoteAPIError.transport("down"))
        api.nowPlayingResult = .failure(RemoteAPIError.transport("down"))
        await vm.refreshNow()
        XCTAssertTrue(vm.isStale)
        XCTAssertTrue(vm.isRestDegraded)

        clock.advance(60)
        XCTAssertEqual(vm.currentPositionMs, 13_000, "过期后应冻结在当前显示位置，不得回退也不算前进")
    }

    func testProgressFrozenInBackground() async {
        let api = MockRemoteAPI()
        let clock = TestMonotonicClock()
        let vm = makeViewModel(api: api, socketFactory: nil, useWebSocket: false, clock: clock)
        await vm.connect()
        defer { vm.disconnect() }

        clock.advance(2)
        XCTAssertEqual(vm.currentPositionMs, 14_000)

        vm.setSceneActive(false)
        clock.advance(120)
        XCTAssertEqual(vm.currentPositionMs, 14_000, "后台冻结在当前显示位置，不得回退")
    }

    // MARK: - 跳转快捷操作

    func testSeekShortcutsClampAndSendOnce() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api, socketFactory: nil, useWebSocket: false)
        await vm.connect()
        defer { vm.disconnect() }

        vm.seekBy(seconds: 15)
        await waitUntil { api.soughtPositions.count == 1 && !vm.isCommandInFlight }
        XCTAssertEqual(api.soughtPositions, [27_000])

        vm.seekToStart()
        await waitUntil { api.soughtPositions.count == 2 && !vm.isCommandInFlight }
        XCTAssertEqual(api.soughtPositions, [27_000, 0])

        vm.seekBy(seconds: -15)
        await waitUntil { api.soughtPositions.count == 3 && !vm.isCommandInFlight }
        XCTAssertEqual(api.soughtPositions.last, 0, "不得为负")
    }

    func testSeekShortcutsDisabledWithoutKnownDuration() async {
        let api = MockRemoteAPI()
        api.statusResult = .success(StatusResponse(state: .playing, position: 0, duration: 0, volume: 0.5, isFinished: false))
        api.nowPlayingResult = .success(NowPlayingResponse(songId: 42, paused: false, playing: true, buffering: false, position: 0, duration: 0, volume: 0.5))
        let vm = makeViewModel(api: api, socketFactory: nil, useWebSocket: false)
        await vm.connect()
        defer { vm.disconnect() }

        XCTAssertFalse(vm.canSeek)
        vm.seekBy(seconds: 15)
        vm.seekToStart()
        await drain()
        XCTAssertTrue(api.soughtPositions.isEmpty)
    }

    // MARK: - 音量快捷操作

    func testMuteAndRestorePreviousVolume() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api, socketFactory: nil, useWebSocket: false)
        await vm.connect()
        defer { vm.disconnect() }

        vm.toggleMute()
        await waitUntil { api.setVolumes.count == 1 && !vm.isCommandInFlight }
        XCTAssertEqual(api.setVolumes.last ?? -1, 0, accuracy: 0.0001)
        XCTAssertTrue(vm.isMuted)

        vm.toggleMute()
        await waitUntil { api.setVolumes.count == 2 && !vm.isCommandInFlight }
        XCTAssertEqual(api.setVolumes.last ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertFalse(vm.isMuted)
    }

    func testVolumeStepAndPresetSendExactlyOneRequest() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api, socketFactory: nil, useWebSocket: false)
        await vm.connect()
        defer { vm.disconnect() }

        vm.adjustVolume(by: 0.05)
        await waitUntil { api.setVolumes.count == 1 && !vm.isCommandInFlight }
        XCTAssertEqual(api.setVolumes.last ?? -1, 0.55, accuracy: 0.0001)

        vm.setVolumePreset(0.75)
        await waitUntil { api.setVolumes.count == 2 && !vm.isCommandInFlight }
        XCTAssertEqual(api.setVolumes.last ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(api.setVolumes.count, 2, "每次点击只发一次请求")
    }

    func testVolumeFailureDoesNotRetry() async {
        let api = MockRemoteAPI()
        api.volumeResult = .failure(RemoteAPIError.transport("down"))
        let vm = makeViewModel(api: api, socketFactory: nil, useWebSocket: false)
        await vm.connect()
        defer { vm.disconnect() }

        vm.adjustVolume(by: 0.05)
        await waitUntil { !api.setVolumes.isEmpty && !vm.isCommandInFlight }
        await drain()
        XCTAssertEqual(api.setVolumes.count, 1, "失败不得自动重试")
        XCTAssertNotNil(vm.lastError)
    }

    // MARK: - 进度钳制 / 缓冲 / 部分事件 / 恢复

    func testPositionBeyondDurationIsClamped() async {
        let api = MockRemoteAPI()
        api.statusResult = .success(StatusResponse(state: .playing, position: 999_999, duration: 240_000, volume: 0.5, isFinished: false))
        api.nowPlayingResult = .success(NowPlayingResponse(songId: 42, paused: false, playing: true, buffering: false, position: 999_999, duration: 240_000, volume: 0.5))
        let clock = TestMonotonicClock()
        let vm = makeViewModel(api: api, socketFactory: nil, useWebSocket: false, clock: clock)
        await vm.connect()
        defer { vm.disconnect() }

        XCTAssertEqual(vm.currentPositionMs, 240_000)
        clock.advance(5)
        XCTAssertEqual(vm.currentPositionMs, 240_000, "基值与外推都不得越过时长")
    }

    func testBufferingStopsAdvance() async {
        let api = MockRemoteAPI()
        api.statusResult = .success(StatusResponse(state: .buffering, position: 12_000, duration: 240_000, volume: 0.5, isFinished: false))
        api.nowPlayingResult = .success(NowPlayingResponse(songId: 42, paused: false, playing: true, buffering: true, position: 12_000, duration: 240_000, volume: 0.5))
        let clock = TestMonotonicClock()
        let vm = makeViewModel(api: api, socketFactory: nil, useWebSocket: false, clock: clock)
        await vm.connect()
        defer { vm.disconnect() }

        XCTAssertEqual(vm.currentPositionMs, 12_000)
        clock.advance(10)
        XCTAssertEqual(vm.currentPositionMs, 12_000, "缓冲中不得推进")
    }

    func testVolumeOnlyWebSocketEventDoesNotRollBack() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let clock = TestMonotonicClock()
        let vm = makeViewModel(api: api, socketFactory: factory.make(), clock: clock)
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }

        clock.advance(2)
        XCTAssertEqual(vm.currentPositionMs, 14_000)

        factory.latest?.emit(.stateChanged(StateChangedPayload(volume: 0.9)))
        await waitUntil { abs(vm.currentVolume - 0.9) < 0.0001 }

        XCTAssertEqual(vm.currentPositionMs, 14_000, "仅音量事件不得回退进度")
        XCTAssertFalse(vm.isStale)
        XCTAssertEqual(vm.transport, .live)
    }

    func testStaleToFreshWebSocketRecoveryAdvances() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let clock = TestMonotonicClock()
        let vm = makeViewModel(api: api, socketFactory: factory.make(), clock: clock)
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }

        clock.advance(1)
        api.statusResult = .failure(RemoteAPIError.transport("down"))
        api.nowPlayingResult = .failure(RemoteAPIError.transport("down"))
        await vm.refreshNow()
        XCTAssertTrue(vm.isStale)

        factory.latest?.emit(.stateChanged(StateChangedPayload(
            songId: 42, paused: false, playing: true, buffering: false,
            durationMs: 240_000, positionMs: 20_000
        )))
        await waitUntil { !vm.isStale }

        XCTAssertEqual(vm.currentPositionMs, 20_000)
        clock.advance(1)
        XCTAssertEqual(vm.currentPositionMs, 21_000, "恢复新鲜后应继续外推")
        XCTAssertFalse(vm.restAvailable, "REST 仍需自身成功证据")
    }

    // MARK: - R6：无关事件不得恢复健康

    func testIrrelevantSocketEventsDoNotRestoreFreshness() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }

        // 让 REST 降级（非致命），socket 保持存活。
        api.statusResult = .failure(RemoteAPIError.transport("down"))
        api.nowPlayingResult = .failure(RemoteAPIError.transport("down"))
        await vm.refreshNow()
        XCTAssertTrue(vm.isStale)
        XCTAssertTrue(vm.isRestDegraded)

        factory.latest?.emit(.hello(clients: 2))
        factory.latest?.emit(.stateChanged(StateChangedPayload()))
        factory.latest?.emit(.stateChanged(StateChangedPayload(dictionary: ["src": "http://secret.example/x"])))
        factory.latest?.emit(.ended)
        await drain()

        XCTAssertTrue(vm.isStale, "无关 / 空 / src-only / ended 事件不得清除过期")
        XCTAssertFalse(vm.canControl)
        XCTAssertFalse(vm.restAvailable)
        XCTAssertTrue(vm.isRestDegraded, "socket 流量不得恢复 REST 可用性")
    }

    func testValidStatusEventRestoresPlaybackFreshnessButNotREST() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }

        api.statusResult = .failure(RemoteAPIError.transport("down"))
        api.nowPlayingResult = .failure(RemoteAPIError.transport("down"))
        await vm.refreshNow()
        XCTAssertTrue(vm.isStale)

        factory.latest?.emit(.stateChanged(StateChangedPayload(
            songId: 42, paused: false, playing: true, buffering: false,
            durationMs: 240_000, positionMs: 40_000
        )))
        await waitUntil { !vm.isStale }

        XCTAssertTrue(vm.canControl, "已验证的状态事件可恢复控制")
        XCTAssertFalse(vm.restAvailable, "但不得声称 REST 可用")
        XCTAssertTrue(vm.isRestDegraded)
    }

    // MARK: - R7：ended 冻结与排序屏障

    func testEndedFreezesAndBlocksOlderPoll() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let clock = TestMonotonicClock()
        let vm = makeViewModel(api: api, socketFactory: factory.make(), clock: clock)
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }
        XCTAssertEqual(vm.playbackState, .playing)

        let gate = AsyncGate()
        api.statusDelay = { await gate.wait() }
        api.nowPlayingDelay = { await gate.wait() }
        api.statusResult = .success(StatusResponse(state: .playing, position: 99_999, duration: 240_000, volume: 0.5, isFinished: false))
        api.nowPlayingResult = .success(NowPlayingResponse(songId: 42, paused: false, playing: true, buffering: false, position: 99_999, duration: 240_000, volume: 0.5))
        let refresh = Task { await vm.refreshNow() }
        await waitUntil { api.statusCallCount >= 2 }

        clock.advance(3)
        let frozen = vm.currentPositionMs

        factory.latest?.emit(.ended)
        await waitUntil { vm.playbackState != .playing }
        XCTAssertEqual(vm.currentPositionMs, frozen, "ended 冻结在当前显示位置")

        clock.advance(60)
        XCTAssertEqual(vm.currentPositionMs, frozen, "ended 后不得推进")

        await gate.open()
        await refresh.value

        XCTAssertEqual(vm.status?.isFinished, true)
        XCTAssertNotEqual(vm.status?.position, 99_999, "较早的轮询不得覆盖终态")
        XCTAssertEqual(vm.currentPositionMs, frozen)
    }

    // MARK: - R4：曲目变化与拖动手势身份

    func testTrackChangeDuringDragDoesNotSeek() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }
        XCTAssertEqual(vm.songId, 42)

        vm.setSeekAdjusting(true)
        vm.updateSeekDraft(50_000)
        XCTAssertEqual(vm.seekDraft, 50_000)

        // 拖动期间曲目切换：旧手势失效。
        factory.latest?.emit(.stateChanged(StateChangedPayload(
            songId: 8, paused: false, playing: true, buffering: false,
            durationMs: 240_000, positionMs: 0
        )))
        await waitUntil { vm.songId == 8 }

        vm.setSeekAdjusting(false)
        await drain()
        XCTAssertTrue(api.soughtPositions.isEmpty, "旧曲目拖动释放不得上报")

        // 新曲目的新手势正常上报。
        vm.setSeekAdjusting(true)
        vm.updateSeekDraft(10_000)
        vm.setSeekAdjusting(false)
        await waitUntil { api.soughtPositions.count == 1 && !vm.isCommandInFlight }
        XCTAssertEqual(api.soughtPositions, [10_000])
    }

    // MARK: - R3：重连使用连接时的不可变配置

    func testSocketRetryUsesConnectionTimeConfiguration() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        var restURLs: [URL] = []
        let settings = makeSettings(useWebSocket: true)
        let vm = makeViewModel(
            api: api,
            settings: settings,
            socketFactory: factory.make(),
            clientFactory: { url, _ in restURLs.append(url); return api }
        )
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }

        // 未保存的编辑（host/token）——绝不能影响已建立的连接或重连。
        settings.host = "10.0.0.9"
        settings.token = "edited-token"

        factory.latest?.simulateRemoteClose()
        await waitUntil { factory.sockets.count >= 2 }
        await waitUntil { vm.transport == .live }

        XCTAssertEqual(factory.requestedBaseURLs.count, 2)
        for url in factory.requestedBaseURLs {
            XCTAssertEqual(url.host, "192.168.31.100")
        }
        XCTAssertEqual(factory.requestedTokens, ["t", "t"])
        XCTAssertEqual(restURLs.compactMap(\.host), ["192.168.31.100"])
    }

    func testAutoConnectUsesSavedConfigAndIsSuppressedAfterUserDisconnect() async {
        let api = MockRemoteAPI()
        let settings = makeSettings(useWebSocket: false)
        settings.autoConnect = true
        let vm = makeViewModel(api: api, settings: settings, socketFactory: nil, useWebSocket: false)
        await vm.connectIfConfigured()
        defer { vm.disconnect() }
        XCTAssertTrue(vm.connection.isConnected, "显式开启且有已保存配置时应自动连接")

        vm.disconnectByUser()
        XCTAssertFalse(vm.connection.isConnected)
        await vm.connectIfConfigured()
        XCTAssertFalse(vm.connection.isConnected, "主动断开后不得自动重连")
    }

    func testAutoConnectDoesNothingWhenDisabledOrUnsaved() async {
        let api = MockRemoteAPI()
        let settings = makeSettings(useWebSocket: false, token: "")
        XCTAssertFalse(settings.autoConnect)
        let vm = makeViewModel(api: api, settings: settings, socketFactory: nil, useWebSocket: false)
        await vm.connectIfConfigured()
        XCTAssertFalse(vm.connection.isConnected)
        XCTAssertEqual(api.infoCallCount, 0)
    }

    // MARK: - 回调身份 / 挂起重连取消

    /// 捕获旧 socket 的回调闭包，在它被替换后再手动触发：必须被世代校验丢弃。
    func testCapturedCallbackFromReplacedSocketIsIgnored() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }

        let captured = factory.latest?.onMessage
        XCTAssertNotNil(captured)

        // 新一次连接取代旧 socket（世代递增）。
        await vm.connect()
        await waitUntil { vm.transport == .live }
        await waitUntil { factory.sockets.count >= 2 }
        XCTAssertEqual(vm.songId, 42)

        // 旧闭包直接触发：不得写入新连接的状态。
        captured?(.stateChanged(StateChangedPayload(songId: 99, playing: true, positionMs: 1_234)))
        await drain()
        XCTAssertNotEqual(vm.songId, 99)
        XCTAssertNotEqual(vm.status?.position, 1_234)
    }

    /// 断开后，待执行的退避重连必须被取消，不得再创建 socket。
    func testPendingReconnectCancelledOnDisconnect() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make(), reconnectDelays: [80_000_000])
        await vm.connect()
        await waitUntil { vm.transport == .live }
        XCTAssertEqual(factory.sockets.count, 1)

        factory.latest?.simulateRemoteClose()
        await waitUntil { vm.transport == .fallback }
        vm.disconnect()

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(factory.sockets.count, 1, "断开后不得继续退避重连")
    }

    // MARK: - 精确修复：新鲜度 / 排序屏障 / 连接替换手势

    func testInsufficientOrInvalidPartialsDoNotRestoreFreshness() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }

        api.statusResult = .failure(RemoteAPIError.transport("down"))
        api.nowPlayingResult = .failure(RemoteAPIError.transport("down"))
        await vm.refreshNow()
        XCTAssertTrue(vm.isStale)

        let socket = factory.latest
        let insufficient: [StateChangedPayload] = [
            StateChangedPayload(ready: false),
            StateChangedPayload(durationMs: 250_000),
            StateChangedPayload(positionMs: -1),
            StateChangedPayload(durationMs: -1)
        ]
        for payload in insufficient {
            socket?.emit(.stateChanged(payload))
            await drain()
            XCTAssertTrue(vm.isStale, "不完整/非法事件不得清除过期：\(payload)")
            XCTAssertFalse(vm.canControl)
        }

        socket?.emit(.stateChanged(StateChangedPayload(
            playing: true, durationMs: 240_000, positionMs: 30_000
        )))
        await waitUntil { !vm.isStale }
        XCTAssertTrue(vm.canControl, "完整合法快照应恢复控制")
    }

    func testVolumeOnlyEventBlocksOlderPoll() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }

        let gate = AsyncGate()
        api.statusDelay = { await gate.wait() }
        api.nowPlayingDelay = { await gate.wait() }
        api.statusResult = .success(StatusResponse(state: .playing, position: 99_999, duration: 240_000, volume: 0.9, isFinished: false))
        api.nowPlayingResult = .success(NowPlayingResponse(songId: 42, paused: false, playing: true, buffering: false, position: 99_999, duration: 240_000, volume: 0.9))

        let refresh = Task { await vm.refreshNow() }
        await waitUntil { api.statusCallCount >= 2 }

        factory.latest?.emit(.stateChanged(StateChangedPayload(volume: 0.1)))
        await waitUntil { abs(vm.currentVolume - 0.1) < 0.0001 }

        await gate.open()
        await refresh.value

        XCTAssertEqual(vm.currentVolume, 0.1, accuracy: 0.0001, "较早的轮询不得覆盖更新的 volume-only 事件")
        XCTAssertNotEqual(vm.status?.position, 99_999)
    }

    func testSongIdOnlyEventBlocksOlderPoll() async {
        let api = MockRemoteAPI()
        let factory = MockSocketFactory()
        let vm = makeViewModel(api: api, socketFactory: factory.make())
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.transport == .live }
        XCTAssertEqual(vm.songId, 42)

        let gate = AsyncGate()
        api.statusDelay = { await gate.wait() }
        api.nowPlayingDelay = { await gate.wait() }
        api.statusResult = .success(StatusResponse(state: .playing, position: 99_999, duration: 240_000, volume: 0.5, isFinished: false))
        api.nowPlayingResult = .success(NowPlayingResponse(songId: 77, paused: false, playing: true, buffering: false, position: 99_999, duration: 240_000, volume: 0.5))

        let refresh = Task { await vm.refreshNow() }
        await waitUntil { api.statusCallCount >= 2 }

        factory.latest?.emit(.stateChanged(StateChangedPayload(songId: 55)))
        await waitUntil { vm.songId == 55 }

        await gate.open()
        await refresh.value

        XCTAssertEqual(vm.songId, 55, "较早的轮询不得覆盖更新的 songId-only 事件")
        XCTAssertNotEqual(vm.status?.position, 99_999)
    }

    func testSeekGestureInvalidatedAcrossReconnectWithSameSong() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api, socketFactory: nil, useWebSocket: false)
        await vm.connect()
        defer { vm.disconnect() }
        XCTAssertEqual(vm.songId, 42)

        vm.setSeekAdjusting(true)
        vm.updateSeekDraft(50_000)
        XCTAssertEqual(vm.seekDraft, 50_000)

        // 重连内部会走 disconnect(resetState: false)，曲目仍为 42（相同 songId）。
        await vm.connect()
        XCTAssertEqual(vm.songId, 42)

        vm.setSeekAdjusting(false)
        await drain()
        XCTAssertTrue(api.soughtPositions.isEmpty, "旧连接的手势释放不得上报")

        vm.setSeekAdjusting(true)
        vm.updateSeekDraft(10_000)
        vm.setSeekAdjusting(false)
        await waitUntil { api.soughtPositions.count == 1 && !vm.isCommandInFlight }
        XCTAssertEqual(api.soughtPositions, [10_000])
    }

    // MARK: - Helpers

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
}
