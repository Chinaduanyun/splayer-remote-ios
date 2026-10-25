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

    private func makeSettings() -> SettingsStore {
        let settings = SettingsStore(defaults: makeDefaults(), tokenStore: InMemoryTokenStore(stored: "t"))
        settings.host = "192.168.31.100"
        settings.portText = "6688"
        settings.useWebSocket = false
        return settings
    }

    private func makeViewModel(api: MockRemoteAPI, factory: MockCollaborationSocketFactory) -> RemoteViewModel {
        RemoteViewModel(
            settings: makeSettings(),
            clientFactory: { _, _ in api },
            pollIntervalNanoseconds: 60_000_000_000,
            socketFactory: nil,
            collaborationSocketFactory: factory.make(),
            wsPollIntervalNanoseconds: 60_000_000_000,
            reconnectDelays: [50_000_000],
            metadataRetryInterval: 15,
            monotonicNow: { 1_000 },
            dateProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func makeQueue(ids: [Int], revision: Int = 5) -> LanShareQueue {
        let tracks = ids.map { LanShareFixtures.track(id: String($0), title: "Track \($0)") }
        let payload: [String: Any] = [
            "ok": true,
            "revision": revision,
            "data": ["playIndex": 0, "tracks": tracks],
        ]
        return try! LanShareQueue.decode(from: JSONSerialization.data(withJSONObject: payload))!
    }

    private func authorizedStatus() -> LanShareStatus {
        LanShareStatus(enabled: true, collabEnabled: true, collabAuthorized: true, wsToken: "synthetic-ws-token")
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
        api.lanShareStatusResult = .success(authorizedStatus())
        api.lanShareQueueResult = .success(makeQueue(ids: [42, 8], revision: 5))
        let factory = MockCollaborationSocketFactory()
        let vm = makeViewModel(api: api, factory: factory)
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { vm.collaborationState == .live }
        await waitUntil { vm.canSelectFromQueue }

        vm.playQueueItem(trackId: "8", index: 1)
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

        // 权威 now-playing 命中期望曲目：清除待确认，且绝不重发。
        api.nowPlayingResult = .success(NowPlayingResponse(songId: 8, paused: false, playing: true, buffering: false, position: 0, duration: 0, volume: 1))
        await vm.refreshNow()

        XCTAssertNil(vm.pendingPlayback, "权威确认后应清除待确认")
        XCTAssertEqual(factory.latest?.sentTexts.count, 1, "确认后不得重发命令")
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

        vm.playQueueItem(trackId: "8", index: 1)
        XCTAssertTrue(factory.sockets.isEmpty)
        XCTAssertNil(vm.pendingPlayback)
    }

    func testPlayQueueItemRejectsStaleRowIdentity() async {
        let api = MockRemoteAPI()
        api.lanShareStatusResult = .success(authorizedStatus())
        api.lanShareQueueResult = .success(makeQueue(ids: [42, 8]))
        let factory = MockCollaborationSocketFactory()
        let vm = makeViewModel(api: api, factory: factory)
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { vm.collaborationState == .live }
        await waitUntil { vm.canSelectFromQueue }

        // 下标 1 实际是 id "8"，传入不匹配的 id 必须被拒绝。
        vm.playQueueItem(trackId: "999", index: 1)
        XCTAssertTrue(factory.latest?.sentTexts.isEmpty ?? true, "行身份不匹配不得发送")
        XCTAssertNil(vm.pendingPlayback)
    }

    func testPlayQueueItemRejectsOutOfRangeIndex() async {
        let api = MockRemoteAPI()
        api.lanShareStatusResult = .success(authorizedStatus())
        api.lanShareQueueResult = .success(makeQueue(ids: [42, 8]))
        let factory = MockCollaborationSocketFactory()
        let vm = makeViewModel(api: api, factory: factory)
        await vm.connect()
        defer { vm.disconnect() }

        await waitUntil { vm.collaborationState == .live }
        await waitUntil { vm.canSelectFromQueue }

        vm.playQueueItem(trackId: "42", index: 99)
        XCTAssertTrue(factory.latest?.sentTexts.isEmpty ?? true, "越界下标不得发送")
    }

    // MARK: - 断线：关闭通道、清空待确认、绝不重放

    func testDisconnectClosesSocketClearsPendingAndNeverReplays() async {
        let api = MockRemoteAPI()
        api.lanShareStatusResult = .success(authorizedStatus())
        api.lanShareQueueResult = .success(makeQueue(ids: [42, 8]))
        let factory = MockCollaborationSocketFactory()
        let vm = makeViewModel(api: api, factory: factory)
        await vm.connect()
        await waitUntil { vm.collaborationState == .live }
        await waitUntil { vm.canSelectFromQueue }

        vm.playQueueItem(trackId: "8", index: 1)
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
