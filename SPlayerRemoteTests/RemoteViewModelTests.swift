import XCTest
@testable import SPlayerRemote

@MainActor
final class RemoteViewModelTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "test-vm-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// 测试默认使用 60s 轮询间隔，避免后台轮询与用例竞争；需要时手动 `refreshNow()`。
    private func makeViewModel(
        api: MockRemoteAPI,
        pollIntervalNanoseconds: UInt64 = 60_000_000_000
    ) -> RemoteViewModel {
        let settings = SettingsStore(defaults: makeDefaults(), tokenStore: InMemoryTokenStore(stored: "t"))
        settings.host = "192.168.31.100"
        settings.portText = "6688"
        return RemoteViewModel(
            settings: settings,
            clientFactory: { _, _ in api },
            pollIntervalNanoseconds: pollIntervalNanoseconds
        )
    }

    // MARK: - 连接

    func testConnectSuccessMarksConnected() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        XCTAssertTrue(vm.connection.isConnected)
        XCTAssertEqual(vm.info?.version, "9.9.9")
        XCTAssertEqual(vm.status?.state, .playing)
        XCTAssertEqual(vm.nowPlaying?.songId, 42)
        XCTAssertFalse(vm.isStale)
        XCTAssertTrue(vm.canControl)
    }

    func testConnectFailsWhenInfoFails() async {
        let api = MockRemoteAPI()
        api.infoResult = .failure(RemoteAPIError.transport("boom"))
        let vm = makeViewModel(api: api)
        await vm.connect()

        guard case .failed = vm.connection else {
            return XCTFail("应处于 failed，实际 \(vm.connection)")
        }
        XCTAssertNotNil(vm.lastError)
        XCTAssertFalse(vm.canControl)
    }

    func testConnectUnauthorizedSurfacesAuthMessage() async {
        let api = MockRemoteAPI()
        api.infoResult = .failure(RemoteAPIError.unauthorized)
        let vm = makeViewModel(api: api)
        await vm.connect()

        guard case .failed(let message) = vm.connection else {
            return XCTFail("应处于 failed，实际 \(vm.connection)")
        }
        XCTAssertTrue(message.contains("401"), message)
    }

    func testInvalidHostFailsWithoutRequest() async {
        let api = MockRemoteAPI()
        let settings = SettingsStore(defaults: makeDefaults(), tokenStore: InMemoryTokenStore())
        settings.host = "http://evil"
        settings.portText = "6688"
        let vm = RemoteViewModel(settings: settings, clientFactory: { _, _ in api })
        await vm.connect()

        guard case .failed = vm.connection else {
            return XCTFail("应处于 failed，实际 \(vm.connection)")
        }
    }

    // MARK: - 场景 / 过期门控

    func testCanControlRequiresActiveScene() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        XCTAssertTrue(vm.canControl)
        vm.setSceneActive(false)
        XCTAssertFalse(vm.canControl)
        vm.setSceneActive(true)
        XCTAssertFalse(vm.canControl, "回前台须先刷新，不能沿用旧状态")
        await vm.refreshNow()
        XCTAssertTrue(vm.canControl)
    }

    func testConnectFinishingAfterBackgroundDoesNotEnableControls() async {
        let api = MockRemoteAPI()
        let gate = AsyncGate()
        api.infoDelay = { await gate.wait() }
        let vm = makeViewModel(api: api)

        let connectTask = Task { await vm.connect() }
        await waitUntil { api.infoCallCount == 1 }

        // 连接在后台完成：不得进入 connected，也不得允许控制。
        vm.setSceneActive(false)
        await gate.open()
        await connectTask.value

        XCTAssertFalse(vm.connection.isConnected)
        XCTAssertFalse(vm.canControl)
    }

    func testBackgroundDiscardsReturningPollUpdate() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        let originalPosition = vm.status?.position
        XCTAssertEqual(originalPosition, 12000)

        let gate = AsyncGate()
        api.statusResult = .success(StatusResponse(state: .playing, position: 99999, duration: 240000, volume: 0.5, isFinished: false))
        api.nowPlayingResult = .success(NowPlayingResponse(songId: 99, paused: false, playing: true, buffering: false, position: 99999, duration: 240000, volume: 0.5))
        api.statusDelay = { await gate.wait() }

        let refresh = Task { await vm.refreshNow() }
        await waitUntil { api.statusCallCount >= 2 }

        vm.setSceneActive(false)
        await gate.open()
        await refresh.value

        // 后台期间返回的刷新结果必须被丢弃。
        XCTAssertEqual(vm.status?.position, 12000)
        XCTAssertEqual(vm.nowPlaying?.songId, 42)
    }

    // MARK: - 过期 / 致命错误

    func testPollTransportErrorMarksStaleAndRecovers() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        api.statusResult = .failure(RemoteAPIError.transport("timeout"))
        api.nowPlayingResult = .failure(RemoteAPIError.transport("timeout"))
        await vm.refreshNow()

        XCTAssertTrue(vm.isStale)
        XCTAssertFalse(vm.canControl)
        XCTAssertNotNil(vm.lastError)
        // 非致命：仍保持连接，轮询继续自动重试。
        XCTAssertTrue(vm.connection.isConnected)

        api.statusResult = .success(StatusResponse(state: .playing, position: 12000, duration: 240000, volume: 0.5, isFinished: false))
        api.nowPlayingResult = .success(NowPlayingResponse(songId: 42, paused: false, playing: true, buffering: false, position: 12000, duration: 240000, volume: 0.5))
        await vm.refreshNow()

        XCTAssertFalse(vm.isStale)
        XCTAssertTrue(vm.canControl)
        XCTAssertNil(vm.lastError)
    }

    func testFatalUnauthorizedStopsPollingAndFails() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()

        api.statusResult = .failure(RemoteAPIError.unauthorized)
        api.nowPlayingResult = .failure(RemoteAPIError.unauthorized)
        await vm.refreshNow()

        guard case .failed(let message) = vm.connection else {
            return XCTFail("应处于 failed，实际 \(vm.connection)")
        }
        XCTAssertTrue(message.contains("401"), message)
        XCTAssertFalse(vm.canControl)
    }

    // MARK: - 命令：互斥 / 延迟 / 取消

    func testCommandsIgnoredWhenDisconnected() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        vm.send(.play)
        await Task.yield()
        XCTAssertTrue(api.sentCommands.isEmpty)
        XCTAssertFalse(vm.isCommandInFlight)
    }

    func testCommandSentWhenConnected() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        vm.send(.play)
        await waitUntil { !api.sentCommands.isEmpty }
        XCTAssertEqual(api.sentCommands, [.play])
    }

    func testDelayedCommandCompletionDoesNotMutateAfterDisconnect() async {
        let api = MockRemoteAPI()
        let gate = AsyncGate()
        api.commandDelay = { await gate.wait() }
        let vm = makeViewModel(api: api)
        await vm.connect()
        XCTAssertTrue(vm.canControl)

        vm.send(.play)
        await waitUntil { api.sentCommands.count == 1 }
        XCTAssertTrue(vm.isCommandInFlight)
        XCTAssertFalse(vm.canControl)

        vm.disconnect()
        XCTAssertFalse(vm.isCommandInFlight)
        XCTAssertFalse(vm.canControl)

        // 释放旧的、已被取代的命令完成；它不得改写已断开的新状态。
        await gate.open()
        await drainMainQueue()

        XCTAssertFalse(vm.isCommandInFlight)
        XCTAssertNil(vm.lastError)
        guard case .disconnected = vm.connection else {
            return XCTFail("应保持断态，实际 \(vm.connection)")
        }
    }

    func testBackgroundCancelsInFlightCommandBusyFlag() async {
        let api = MockRemoteAPI()
        let gate = AsyncGate()
        api.commandDelay = { await gate.wait() }
        let vm = makeViewModel(api: api)
        await vm.connect()

        vm.send(.next)
        await waitUntil { api.sentCommands.count == 1 }
        XCTAssertTrue(vm.isCommandInFlight)

        vm.setSceneActive(false)
        XCTAssertFalse(vm.isCommandInFlight)
        XCTAssertFalse(vm.canControl)

        await gate.open()
        await drainMainQueue()
        XCTAssertFalse(vm.isCommandInFlight)

        vm.disconnect()
    }

    // MARK: - 音量 / 跳转钳制

    func testVolumeCommitClampsAndSendsOnce() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        vm.volumeDraft = 5
        vm.setVolumeAdjusting(false) // 松手 -> 上报
        await waitUntil { !api.setVolumes.isEmpty }
        XCTAssertEqual(api.setVolumes, [1.0])
    }

    func testSeekCommitClampsToDuration() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        vm.seekDraft = 9_999_999
        vm.setSeekAdjusting(false)
        await waitUntil { !api.soughtPositions.isEmpty }
        XCTAssertEqual(api.soughtPositions, [240_000])
    }

    func testCommandsDisabledWhileStale() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()

        api.statusResult = .failure(RemoteAPIError.transport("down"))
        api.nowPlayingResult = .failure(RemoteAPIError.transport("down"))
        await vm.refreshNow()
        XCTAssertFalse(vm.canControl)

        vm.send(.play)
        await Task.yield()
        XCTAssertTrue(api.sentCommands.isEmpty, "过期状态下不得发送命令")

        vm.disconnect()
    }

    func testMessageLocalizesKnownErrors() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        XCTAssertTrue(vm.message(for: RemoteAPIError.unauthorized).contains("401"))
        XCTAssertTrue(vm.message(for: RemoteAPIError.forbidden).contains("403"))
        XCTAssertTrue(vm.message(for: RemoteAPIError.unexpectedResponse).contains("ok:true"))
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

    /// 让主队列上的挂起任务有机会恢复执行。
    private func drainMainQueue() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}
