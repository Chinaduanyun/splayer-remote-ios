import XCTest
@testable import SPlayerRemote

/// v1.3 协作点播：授权门控、单连接生命周期、playAt 一次性发送与权威确认。
/// 全部使用合成夹具，不含真实 IP / Token / 用户数据。
@MainActor
final class CollaborationTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "test-collab-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeSettings(useWebSocket: Bool = false) -> SettingsStore {
        let settings = SettingsStore(defaults: makeDefaults(), tokenStore: InMemoryTokenStore(stored: "t"))
        settings.host = "192.168.31.100"
        settings.portText = "6688"
        settings.useWebSocket = useWebSocket
        return settings
    }

    private func makeViewModel(
        api: MockRemoteAPI,
        factory: MockCollaborationSocketFactory,
        socketFactory: RemoteSocketFactory? = nil,
        useWebSocket: Bool = false,
        timeoutNanoseconds: UInt64 = 12_000_000_000
    ) -> RemoteViewModel {
        RemoteViewModel(
            settings: makeSettings(useWebSocket: useWebSocket),
            clientFactory: { _, _ in api },
            pollIntervalNanoseconds: 60_000_000_000,
            socketFactory: socketFactory,
            collaborationSocketFactory: factory.make(),
            wsPollIntervalNanoseconds: 60_000_000_000,
            reconnectDelays: [50_000_000],
            metadataRetryInterval: 15,
            collaborationTimeoutNanoseconds: timeoutNanoseconds,
            monotonicNow: { 1_000 },
            dateProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func makeQueue(ids: [Int], revision: Int = 5) -> LanShareQueue {
        let tracks = ids.map { LanShareFixtures.track(id: String($0), title: "Track \($0)") }
        return makeQueue(rawTracks: tracks, revision: revision)
    }

    private func makeQueue(rawTracks: [[String: Any]], revision: Int) -> LanShareQueue {
        let payload: [String: Any] = [
            "ok": true,
            "revision": revision,
            "data": ["playIndex": 0, "tracks": rawTracks],
        ]
        return try! LanShareQueue.decode(from: JSONSerialization.data(withJSONObject: payload))!
    }

    private func authorizedStatus() -> LanShareStatus {
        LanShareStatus(enabled: true, collabEnabled: true, collabAuthorized: true, wsToken: "synthetic-ws-token")
    }

    /// 完成连接并等到协作通道可控、当前世代队列已刷新。
    private func makeLiveViewModel(
        api: MockRemoteAPI,
        factory: MockCollaborationSocketFactory,
        queue: LanShareQueue? = nil,
        socketFactory: RemoteSocketFactory? = nil,
        useWebSocket: Bool = false,
        timeoutNanoseconds: UInt64 = 12_000_000_000
    ) async -> RemoteViewModel {
        api.lanShareStatusResult = .success(authorizedStatus())
        api.lanShareQueueResult = .success(queue ?? makeQueue(ids: [42, 8]))
        let vm = makeViewModel(
            api: api,
            factory: factory,
            socketFactory: socketFactory,
            useWebSocket: useWebSocket,
            timeoutNanoseconds: timeoutNanoseconds
        )
        await vm.connect()
        await waitUntil { vm.collaborationState == .live }
        await waitUntil { vm.canSelectFromQueue }
        return vm
    }

    func testDiscoveryMutationBarrierRejectsOldAndPremutationSnapshots() async throws {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory)
        defer { vm.disconnectByUser() }
        let old = try XCTUnwrap(vm.makeQueueSelection(for: try XCTUnwrap(track(vm, id: "8"))))
        var resumeOld: CheckedContinuation<Void, Never>?
        api.lanShareQueueDelay = { await withCheckedContinuation { resumeOld = $0 } }
        let preRead = Task { await vm.refreshMetadataNow() }
        await waitUntil { resumeOld != nil }
        let lease = try XCTUnwrap(vm.acquireDiscoveryCommand())
        let barrier = try XCTUnwrap(vm.beginDiscoveryQueueMutation(lease))
        vm.releaseDiscoveryCommand(lease)
        XCTAssertFalse(vm.canSelectFromQueue)
        vm.playQueueItem(old)
        XCTAssertNil(vm.pendingPlayback)
        // A pre-barrier response must not restore eligibility, even with same playing ID.
        resumeOld?.resume()
        await preRead.value
        XCTAssertFalse(vm.canSelectFromQueue)
        api.lanShareQueueDelay = nil
        vm.resolveDiscoveryQueueMutation(barrier, generation: vm.generation)
        api.lanShareQueueResult = .failure(URLError(.networkConnectionLost))
        await vm.finishDiscoveryQueueMutation(barrier, generation: vm.generation)
        XCTAssertFalse(vm.canSelectFromQueue)
        api.lanShareQueueResult = .success(makeQueue(ids: [42, 99]))
        var resumeNew: CheckedContinuation<Void, Never>?
        api.lanShareQueueDelay = { await withCheckedContinuation { resumeNew = $0 } }
        let postRead = Task { await vm.finishDiscoveryQueueMutation(barrier, generation: vm.generation) }
        await waitUntil { resumeNew != nil }
        vm.playQueueItem(old)
        XCTAssertNil(vm.pendingPlayback)
        XCTAssertFalse(vm.canSelectFromQueue)
        resumeNew?.resume()
        await postRead.value
        XCTAssertTrue(vm.canSelectFromQueue)
        vm.playQueueItem(old)
        XCTAssertNil(vm.pendingPlayback)
        XCTAssertEqual(vm.queue?.tracks.last?.id, "99")
    }

    func testLostAcceptedPOSTCannotUnlockBeforeTerminalStatusAndOrderedRead() async throws {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory)
        defer { vm.disconnectByUser() }
        let old = try XCTUnwrap(vm.makeQueueSelection(for: try XCTUnwrap(track(vm, id: "8"))))
        let discovery = LostAcceptedDiscoveryAPI()
        let model = DiscoveryViewModel(factory: { _ in discovery }, now: { Date(timeIntervalSince1970: 1) }, pollLimit: 1, sleep: {})
        await model.connect(remote: vm)
        await model.query("discovery/daily-songs")
        await model.play(0, remote: vm)
        XCTAssertEqual(discovery.posts, 1)
        XCTAssertTrue(model.needsReconciliation)
        XCTAssertFalse(vm.canSelectFromQueue)
        // A successful old queue GET while execution is held is not ordering proof.
        let prematureSnapshot = try await api.fetchLanShareQueue()
        XCTAssertEqual(prematureSnapshot?.tracks.last?.id, "8")
        let readsBeforeManualRefresh = api.lanShareQueueCallCount
        await vm.refreshMetadataNow()
        XCTAssertEqual(api.lanShareQueueCallCount, readsBeforeManualRefresh)
        XCTAssertFalse(vm.canSelectFromQueue)
        vm.playQueueItem(old)
        XCTAssertNil(vm.pendingPlayback)
        await model.reconcile(remote: vm) // pending: still no ordering proof
        XCTAssertFalse(vm.canSelectFromQueue)
        // Release held Android execution; terminal status now precedes the eligible queue GET.
        api.lanShareQueueResult = .success(makeQueue(ids: [42, 99]))
        discovery.applied = true
        await model.reconcile(remote: vm)
        XCTAssertEqual(discovery.posts, 1)
        XCTAssertFalse(model.needsReconciliation)
        XCTAssertTrue(vm.canSelectFromQueue)
        XCTAssertEqual(vm.queue?.tracks.last?.id, "99")
        vm.playQueueItem(old)
        XCTAssertNil(vm.pendingPlayback)
    }

    private func track(_ vm: RemoteViewModel, id: String) -> LanShareTrack? {
        vm.queue?.tracks.first(where: { $0.id == id })
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
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
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    // MARK: - 授权门控

    func testUnauthorizedQueueStaysReadOnlyAndOpensNoSocket() async {
        let api = MockRemoteAPI()
        api.lanShareStatusResult = .success(LanShareStatus(enabled: true, collabEnabled: true, collabAuthorized: false, wsToken: nil))
        api.lanShareQueueResult = .success(makeQueue(ids: [42, 8]))
        let factory = MockCollaborationSocketFactory()
        let vm = makeViewModel(api: api, factory: factory)
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { vm.metadataState == .available }
        await waitUntil { api.lanShareStatusCallCount >= 1 }
        await waitUntil { vm.collaborationState == .unauthorized }

        XCTAssertFalse(vm.canSelectFromQueue, "未授权时队列必须只读")
        XCTAssertTrue(factory.sockets.isEmpty, "未授权不得建立协作通道")
        XCTAssertNotNil(vm.queueReadOnlyHint)
    }

    func testAuthorizedWithoutTokenStaysReadOnly() async {
        let api = MockRemoteAPI()
        api.lanShareStatusResult = .success(LanShareStatus(enabled: true, collabEnabled: true, collabAuthorized: true, wsToken: nil))
        let factory = MockCollaborationSocketFactory()
        let vm = makeViewModel(api: api, factory: factory)
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { api.lanShareStatusCallCount >= 1 }
        await waitUntil { vm.collaborationState == .unauthorized }
        XCTAssertTrue(factory.sockets.isEmpty, "缺少 wsToken 时不得建立协作通道")
    }

    func testDisabledCollaborationIsReadOnly() async {
        let api = MockRemoteAPI()
        api.lanShareStatusResult = .success(LanShareStatus(enabled: true, collabEnabled: false, collabAuthorized: false, wsToken: nil))
        let factory = MockCollaborationSocketFactory()
        let vm = makeViewModel(api: api, factory: factory)
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { api.lanShareStatusCallCount >= 1 }
        await waitUntil { vm.collaborationState == .disabled }
        XCTAssertTrue(factory.sockets.isEmpty)
    }

    // MARK: - 单连接 + 查询串 token

    func testAuthorizedStartsSingleCollaborationSocketWithQueryToken() async {
        let api = MockRemoteAPI()
        api.lanShareStatusResult = .success(authorizedStatus())
        api.lanShareQueueResult = .success(makeQueue(ids: [42, 8]))
        let factory = MockCollaborationSocketFactory()
        let vm = makeViewModel(api: api, factory: factory)
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { vm.collaborationState == .live }
        XCTAssertEqual(factory.sockets.count, 1, "只应建立单条协作连接")

        let url = try? XCTUnwrap(factory.requestedURLs.last)
        XCTAssertEqual(url?.path, "/api/lanShare/ws")
        XCTAssertEqual(url?.scheme, "ws")
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "token" })?.value, "synthetic-ws-token")
        XCTAssertNil(components?.queryItems?.first(where: { $0.name == "role" }), "不得冒充 host")

        await waitUntil { vm.canSelectFromQueue }
    }

    // MARK: - 点播：一次性 playAt + 权威确认

    func testPlayQueueItemSendsSinglePlayAtThenConfirms() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory, queue: makeQueue(ids: [42, 8], revision: 5))
        defer { vm.disconnect() }

        let selection = try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "8"))))
        vm.playQueueItem(selection)
        XCTAssertEqual(factory.latest?.sentTexts.count, 1, "必须只发送一次 playAt")

        if let text = factory.latest?.sentTexts.first,
           let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            XCTAssertEqual(json["type"] as? String, "command")
            XCTAssertEqual(json["action"] as? String, "playAt")
            XCTAssertEqual(json["value"] as? Int, 1, "playAt 必须使用 0 基下标")
        } else {
            XCTFail("playAt 负载应为合法 JSON")
        }

        let pending = try? XCTUnwrap(vm.pendingPlayback)
        XCTAssertEqual(pending?.trackId, "8")
        XCTAssertEqual(pending?.revision, 5)
        XCTAssertFalse(vm.canControl, "待确认期间共享命令槽被占用")

        // 权威 now-playing 命中期望曲目：清除待确认，且绝不重发。
        api.nowPlayingResult = .success(NowPlayingResponse(songId: 8, paused: false, playing: true, buffering: false, position: 0, duration: 0, volume: 1))
        await vm.refreshNow()

        XCTAssertNil(vm.pendingPlayback, "权威确认后应清除待确认")
        XCTAssertEqual(factory.latest?.sentTexts.count, 1, "确认后不得重发命令")
        XCTAssertTrue(vm.canControl, "确认后应释放共享命令槽")
    }

    func testPlayQueueItemRejectedWhenChannelNotLive() async {
        let api = MockRemoteAPI()
        api.lanShareStatusResult = .success(LanShareStatus(enabled: true, collabEnabled: true, collabAuthorized: false, wsToken: nil))
        api.lanShareQueueResult = .success(makeQueue(ids: [42, 8]))
        let factory = MockCollaborationSocketFactory()
        let vm = makeViewModel(api: api, factory: factory)
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { vm.metadataState == .available }
        await waitUntil { api.lanShareStatusCallCount >= 1 }
        await waitUntil { vm.collaborationState == .unauthorized }

        let selection = try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "8"))))
        vm.playQueueItem(selection)
        XCTAssertTrue(factory.sockets.isEmpty)
        XCTAssertNil(vm.pendingPlayback)
    }

    func testPlayQueueItemRejectsStaleRowIdentity() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory)
        defer { vm.disconnect() }

        let base = try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "8"))))
        let stale = QueueSelectionIdentity(
            trackId: "999",
            source: base.source,
            upstreamIndex: base.upstreamIndex,
            revision: base.revision,
            queueGeneration: base.queueGeneration,
            connectionGeneration: base.connectionGeneration
        )
        vm.playQueueItem(stale)
        XCTAssertTrue(factory.latest?.sentTexts.isEmpty ?? true, "行身份不匹配不得发送")
        XCTAssertNil(vm.pendingPlayback)
    }

    func testPlayQueueItemRejectsUnknownUpstreamIndex() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory)
        defer { vm.disconnect() }

        let base = try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "42"))))
        let unknown = QueueSelectionIdentity(
            trackId: base.trackId,
            source: base.source,
            upstreamIndex: 99,
            revision: base.revision,
            queueGeneration: base.queueGeneration,
            connectionGeneration: base.connectionGeneration
        )
        vm.playQueueItem(unknown)
        XCTAssertTrue(factory.latest?.sentTexts.isEmpty ?? true, "未知主机下标不得发送")
    }

    // MARK: - F3 / F4：主机原始下标、revision、队列世代与来源身份

    func testInvalidRowBeforeValidPreservesHostIndex() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let lossy = makeQueue(rawTracks: [
            ["title": "row without id"],
            LanShareFixtures.track(id: "9", title: "valid row"),
        ], revision: 9)
        let vm = await makeLiveViewModel(api: api, factory: factory, queue: lossy)
        defer { vm.disconnect() }

        let valid = try! XCTUnwrap(track(vm, id: "9"))
        XCTAssertEqual(vm.queue?.tracks.count, 1, "无 id 行会被解码器丢弃")
        XCTAssertEqual(valid.upstreamIndex, 1, "必须保留主机原始下标")

        vm.playQueueItem(try! XCTUnwrap(vm.makeQueueSelection(for: valid)))
        guard let text = factory.latest?.sentTexts.first,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return XCTFail("应发送 playAt")
        }
        XCTAssertEqual(json["value"] as? Int, 1, "必须发送主机下标 1，而不是展示下标 0")
    }

    func testDuplicateIdsUseSelectedUpstreamIndex() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let duplicates = makeQueue(rawTracks: [
            LanShareFixtures.track(id: "7", source: "netease", title: "first"),
            LanShareFixtures.track(id: "7", source: "local", title: "second"),
        ], revision: 2)
        let vm = await makeLiveViewModel(api: api, factory: factory, queue: duplicates)
        defer { vm.disconnect() }

        let second = try! XCTUnwrap(vm.queue?.tracks.last)
        XCTAssertEqual(second.upstreamIndex, 1)
        vm.playQueueItem(try! XCTUnwrap(vm.makeQueueSelection(for: second)))
        guard let text = factory.latest?.sentTexts.first,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return XCTFail("应发送 playAt")
        }
        XCTAssertEqual(json["value"] as? Int, 1, "重复 id 必须按所选主机下标消除歧义")
    }

    func testRevisionChangeInvalidatesRenderedSelection() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory, queue: makeQueue(ids: [42, 8], revision: 5))
        defer { vm.disconnect() }

        let selection = try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "8"))))
        api.lanShareQueueResult = .success(makeQueue(ids: [42, 8], revision: 6))
        await vm.refreshMetadataNow()
        await waitUntil { vm.queue?.revision == 6 }

        vm.playQueueItem(selection)
        XCTAssertTrue(factory.latest?.sentTexts.isEmpty ?? true, "revision 变化后旧选择不得发送")
        XCTAssertNotNil(vm.collaborationMessage)
    }

    func testStaleRenderedQueueGenerationRejected() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory, queue: makeQueue(ids: [42, 8], revision: 5))
        defer { vm.disconnect() }

        let selection = try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "8"))))
        // 内容与 revision 不变，但重新安装了新队列：渲染世代必须失效。
        await vm.refreshMetadataNow()
        await waitUntil { vm.queueGeneration != selection.queueGeneration }

        vm.playQueueItem(selection)
        XCTAssertTrue(factory.latest?.sentTexts.isEmpty ?? true, "过期队列世代不得发送")
    }

    func testSourceChangeRejectedForSameIdAndIndex() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory)
        defer { vm.disconnect() }

        let base = try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "8"))))
        let wrongSource = QueueSelectionIdentity(
            trackId: base.trackId,
            source: "different-source",
            upstreamIndex: base.upstreamIndex,
            revision: base.revision,
            queueGeneration: base.queueGeneration,
            connectionGeneration: base.connectionGeneration
        )
        vm.playQueueItem(wrongSource)
        XCTAssertTrue(factory.latest?.sentTexts.isEmpty ?? true, "来源身份变化不得发送")
    }

    func testConnectionGenerationChangeRejected() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory)
        defer { vm.disconnect() }

        let base = try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "8"))))
        let oldGeneration = QueueSelectionIdentity(
            trackId: base.trackId,
            source: base.source,
            upstreamIndex: base.upstreamIndex,
            revision: base.revision,
            queueGeneration: base.queueGeneration,
            connectionGeneration: base.connectionGeneration - 1
        )
        vm.playQueueItem(oldGeneration)
        XCTAssertTrue(factory.latest?.sentTexts.isEmpty ?? true, "旧连接世代不得发送")
    }

    func testRestDegradedWithHealthySocketKeepsQueueReadOnly() async {
        let api = MockRemoteAPI()
        let collabFactory = MockCollaborationSocketFactory()
        let wsFactory = MockSocketFactory()
        let vm = await makeLiveViewModel(
            api: api,
            factory: collabFactory,
            socketFactory: wsFactory.make(),
            useWebSocket: true
        )
        defer { vm.disconnect() }

        // REST 降级（非致命网络错误）。
        api.statusResult = .failure(RemoteAPIError.transport("down"))
        api.nowPlayingResult = .failure(RemoteAPIError.transport("down"))
        await vm.refreshNow()
        XCTAssertTrue(vm.isRestDegraded)

        // 健康的外部 WS 只清除 isStale，绝不清除 isRestDegraded。
        wsFactory.latest?.emit(.stateChanged(StateChangedPayload(playing: true, positionMs: 1_000)))
        await waitUntil { !vm.isStale }
        XCTAssertTrue(vm.isRestDegraded, "外部 WS 不得清除 REST 降级")
        XCTAssertFalse(vm.canSelectFromQueue, "REST 降级时即使 WS 健康也不得点播")
    }

    func testForegroundRequiresQueueRefreshBeforeSelection() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory)
        defer { vm.disconnect() }
        XCTAssertTrue(vm.canSelectFromQueue)

        vm.setSceneActive(false) // background：递增世代并作废队列新鲜度
        XCTAssertFalse(vm.canSelectFromQueue)

        vm.setSceneActive(true) // foreground：异步刷新授权 + 队列
        XCTAssertFalse(vm.canSelectFromQueue, "回前台后、当前世代队列刷新完成前必须只读")
        await waitUntil { vm.canSelectFromQueue }
    }

    // MARK: - F5：共享命令槽 / 快速连点 / 冲突 / 超时释放

    func testRapidSecondSelectionAndHttpActionAreBlocked() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory)
        defer { vm.disconnect() }

        let first = try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "8"))))
        let second = try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "42"))))

        vm.playQueueItem(first)
        vm.playQueueItem(second) // 快速第二次点播：pending 占用命令槽，必须被拒绝
        vm.send(.play)           // 冲突的 HTTP 控制也必须被拒绝
        await drain()

        XCTAssertEqual(factory.latest?.sentTexts.count, 1, "只允许一次 playAt")
        XCTAssertEqual(vm.pendingPlayback?.trackId, "8", "待确认目标不得被第二次点击替换")
        XCTAssertTrue(api.sentCommands.isEmpty, "待确认期间 HTTP 控制不得派发")
    }

    func testPendingTimeoutReleasesCommandGate() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory, timeoutNanoseconds: 50_000_000)
        defer { vm.disconnect() }

        vm.playQueueItem(try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "8")))))
        XCTAssertNotNil(vm.pendingPlayback)
        await waitUntil { vm.pendingPlayback == nil }
        XCTAssertTrue(vm.collaborationMessage?.contains("确认") == true)
        XCTAssertTrue(vm.canControl, "超时后必须释放共享命令槽")

        vm.send(.play)
        await waitUntil { !api.sentCommands.isEmpty }
        XCTAssertEqual(api.sentCommands, [.play])
        XCTAssertEqual(factory.latest?.sentTexts.count, 1, "超时绝不重发 playAt")
    }

    // MARK: - F6：非预期关闭 / 致命鉴权 / 迟到回调

    func testUnexpectedCloseClearsPendingAndTearsDown() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory)
        defer { vm.disconnect() }

        vm.playQueueItem(try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "8")))))
        let socket = try! XCTUnwrap(factory.latest)
        socket.simulateRemoteClose()

        await waitUntil { vm.pendingPlayback == nil }
        await waitUntil { vm.collaborationState != .live }
        XCTAssertGreaterThanOrEqual(socket.stopCount, 1, "非预期关闭必须走 teardown / stop")
        XCTAssertTrue(vm.collaborationMessage?.contains("断开") == true)
    }

    func testFatalAuthClearsPendingAndTearsDown() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory)
        defer { vm.disconnect() }

        vm.playQueueItem(try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "8")))))
        let socket = try! XCTUnwrap(factory.latest)
        api.statusResult = .failure(RemoteAPIError.unauthorized)
        await vm.refreshNow()

        XCTAssertNil(vm.pendingPlayback, "致命鉴权失败必须清空待确认")
        XCTAssertEqual(vm.collaborationState, .disabled, "致命鉴权失败必须重置协作通道")
        XCTAssertGreaterThanOrEqual(socket.stopCount, 1)
        XCTAssertFalse(vm.canSelectFromQueue)
    }

    func testLateSocketCallbackAfterTeardownCannotReopen() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory)
        defer { vm.disconnect() }

        let socket = try! XCTUnwrap(factory.latest)
        let lateHandler = socket.onStateChange
        socket.simulateRemoteClose()
        await waitUntil { vm.collaborationState != .live }

        // 已 teardown 的 socket 的迟到 open 回调必须被世代校验丢弃。
        lateHandler?(.open)
        await drain()
        XCTAssertNotEqual(vm.collaborationState, .live, "迟到回调不得重建协作通道")
    }

    // MARK: - F2：授权状态请求世代 / 身份 / 取消

    func testDelayedOldAuthorizationDoesNotOverrideReplacementConnection() async {
        let api = MockRemoteAPI()
        let gate = AsyncGate()
        api.lanShareStatusResult = .success(authorizedStatus())
        api.lanShareStatusDelay = {
            if api.lanShareStatusCallCount == 1 { await gate.wait() }
        }
        let factory = MockCollaborationSocketFactory()
        let vm = makeViewModel(api: api, factory: factory)

        await vm.connect() // 第一次连接：授权请求被挂起
        await waitUntil { api.lanShareStatusCallCount == 1 }

        // 替换连接（同主机、新世代 / 可能新凭据）。
        api.lanShareStatusResult = .success(LanShareStatus(enabled: true, collabEnabled: true, collabAuthorized: false, wsToken: nil))
        await vm.connect()
        await waitUntil { api.lanShareStatusCallCount >= 2 }
        await waitUntil { vm.collaborationState == .unauthorized }

        await gate.open()
        await drain()
        XCTAssertEqual(vm.collaborationState, .unauthorized, "旧授权成功响应不得覆盖替换后的连接")
        XCTAssertTrue(factory.sockets.isEmpty, "旧授权结果不得建立协作通道")
        vm.disconnect()
    }

    func testBackgroundInvalidatesOutstandingAuthorizationAndRefetches() async {
        let api = MockRemoteAPI()
        let gate = AsyncGate()
        api.lanShareStatusResult = .success(authorizedStatus())
        api.lanShareStatusDelay = {
            if api.lanShareStatusCallCount == 1 { await gate.wait() }
        }
        let factory = MockCollaborationSocketFactory()
        let vm = makeViewModel(api: api, factory: factory)

        await vm.connect()
        await waitUntil { api.lanShareStatusCallCount == 1 }

        vm.setSceneActive(false) // 后台：作废在途授权请求
        vm.setSceneActive(true)  // 前台：必须发起自己的授权请求

        await waitUntil { api.lanShareStatusCallCount >= 2 }
        await waitUntil { vm.collaborationState == .live }

        await gate.open()
        await drain()
        XCTAssertEqual(vm.collaborationState, .live, "旧请求完成后不得改变前台新结果")
        vm.disconnect()
    }

    // MARK: - 断线：关闭通道、清空待确认、绝不重放

    func testDisconnectClosesSocketClearsPendingAndNeverReplays() async {
        let api = MockRemoteAPI()
        let factory = MockCollaborationSocketFactory()
        let vm = await makeLiveViewModel(api: api, factory: factory)

        vm.playQueueItem(try! XCTUnwrap(vm.makeQueueSelection(for: try! XCTUnwrap(track(vm, id: "8")))))
        let firstSocket = factory.latest
        XCTAssertEqual(firstSocket?.sentTexts.count, 1)

        vm.disconnect()
        XCTAssertNil(vm.pendingPlayback, "断线必须清空待确认")
        XCTAssertEqual(firstSocket?.stopCount, 1, "断线必须关闭协作通道")

        // 重新连接不得重放之前的命令。
        await vm.connect()
        defer { vm.disconnect() }
        await waitUntil { vm.collaborationState == .live }
        XCTAssertTrue(factory.latest?.sentTexts.isEmpty ?? true, "重连后绝不重放旧命令")
    }
}


private final class LostAcceptedDiscoveryAPI: DiscoveryAPI {
    var posts = 0
    var applied = false
    private var command = UUID()
    func get<T: Decodable>(_ path: String, query: [URLQueryItem], as: T.Type) async throws -> T {
        let json: String
        if path == "capabilities" {
            json = """
            {"protocolVersion":1,"serverSessionId":"held-session","accountState":"signedIn","rendererReady":true,"collabAuthorized":true}
            """
        } else if path.hasPrefix("commands/") {
            XCTAssertEqual(path, "commands/\(command.uuidString)")
            XCTAssertEqual(query.first?.value, "held-session")
            json = "{\"commandId\":\"\(command.uuidString)\",\"state\":\"\(applied ? "applied" : "pending")\"}"
        } else {
            json = """
            {"selectionId":"11111111-1111-4111-8111-111111111111","expiresAt":200000,"items":[{"id":"42","title":"Song","artists":[]}],"offset":0,"nextOffset":null,"truncated":false}
            """
        }
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
    func submit(session: String, selection: UUID, index: Int, command: UUID) async throws -> DiscoveryCommandStatus {
        posts += 1
        self.command = command // accepted; execution deliberately held until test sets applied
        throw URLError(.networkConnectionLost)
    }
}
