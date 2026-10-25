#if canImport(ActivityKit)
import XCTest
import Foundation
@testable import SPlayerRemote

/// Live Activity 控制器的有序性 / 限频 / end 语义，以及 intent 反馈的曲目与新鲜度规则。
@available(iOS 17.0, *)
@MainActor
final class LiveActivityControllerTests: XCTestCase {

    // MARK: - Helpers

    private func snapshot(
        title: String = "Song",
        artist: String = "Artist",
        songId: String = "1",
        isPlaying: Bool = true,
        isBuffering: Bool = false,
        connectionAvailable: Bool = true,
        timestamp: Date = Date(timeIntervalSince1970: 1_000)
    ) -> RemoteActivitySnapshot {
        RemoteActivitySnapshot(
            title: title,
            artist: artist,
            songId: songId,
            isPlaying: isPlaying,
            isBuffering: isBuffering,
            connectionAvailable: connectionAvailable,
            timestamp: timestamp
        )
    }

    private func state(
        title: String = "Old",
        artist: String = "Old artist",
        songId: String = "1",
        isPlaying: Bool = true,
        isBuffering: Bool = false,
        lastUpdate: Date = Date(timeIntervalSince1970: 500),
        connectionAvailable: Bool = true
    ) -> RemoteActivityAttributes.ContentState {
        .init(
            title: title,
            artist: artist,
            songId: songId,
            isPlaying: isPlaying,
            isBuffering: isBuffering,
            lastUpdate: lastUpdate,
            connectionAvailable: connectionAvailable
        )
    }

    // MARK: - 有序 / 限频（F4）

    func testTwoInitialUpdatesSerializeToOneActivity() async {
        let backend = SpyLiveActivityBackend()
        var now: TimeInterval = 100
        let controller = LiveActivityController(
            userEnabled: true,
            minUpdateInterval: 0,
            backend: backend,
            uptime: { now }
        )

        controller.startOrUpdate(snapshot(title: "A"))
        now += 1
        controller.startOrUpdate(snapshot(title: "B"))
        await controller.waitForPendingOperations()

        XCTAssertEqual(backend.requestCount, 1, "并发的首次更新只应创建一个 Activity")
        XCTAssertEqual(backend.updateCount, 1, "后续更新应走 update")
    }

    func testTimestampOnlyBurstIsBoundedByContentKey() async {
        let backend = SpyLiveActivityBackend()
        var now: TimeInterval = 100
        let controller = LiveActivityController(
            userEnabled: true,
            minUpdateInterval: 2,
            backend: backend,
            uptime: { now }
        )

        for index in 0..<5 {
            now = 100 + Double(index)
            controller.startOrUpdate(snapshot(timestamp: Date(timeIntervalSince1970: 1_000 + Double(index))))
        }
        await controller.waitForPendingOperations()

        XCTAssertEqual(backend.requestCount + backend.updateCount, 3, "4 秒内按 2 秒间隔接收 3 次心跳，间隔内更新应被抑制")
    }

    /// R3：内容持续变化的突发也应被合幷为每区间一次，最终快照必须交付。
    func testChangedContentBurstCoalescesAndDeliversLatest() async {
        let backend = SpyLiveActivityBackend()
        var now: TimeInterval = 100
        let controller = LiveActivityController(
            userEnabled: true,
            minUpdateInterval: 2,
            backend: backend,
            uptime: { now }
        )

        for index in 0..<5 {
            now = 100 + Double(index)
            controller.startOrUpdate(snapshot(title: "Title \(index)", timestamp: Date(timeIntervalSince1970: Double(index))))
        }
        await controller.waitForPendingOperations()

        XCTAssertEqual(backend.requestCount + backend.updateCount, 3, "变化的标题突发应被合并为每 2 秒一次")
        XCTAssertEqual(backend.lastTitle, "Title 4", "最终快照必须被交付")
    }

    /// R3：播放 / 暂停等生命周期变化立即交付，不受限频影响。
    func testPlaybackLifecycleChangeBypassesThrottle() async {
        let backend = SpyLiveActivityBackend()
        var now: TimeInterval = 100
        let controller = LiveActivityController(
            userEnabled: true,
            minUpdateInterval: 2,
            backend: backend,
            uptime: { now }
        )

        controller.startOrUpdate(snapshot(title: "A", isPlaying: true))
        now = 100.5
        controller.startOrUpdate(snapshot(title: "A", isPlaying: false))
        await controller.waitForPendingOperations()

        XCTAssertEqual(backend.requestCount + backend.updateCount, 2, "播放 / 暂停变化必须立即交付")
    }

    // MARK: - F7：尾随合幷交付（无额外输入）

    func testTrailingSnapshotDeliveredWithoutFurtherInput() async {
        let backend = SpyLiveActivityBackend()
        var now: TimeInterval = 100
        let scheduler = ManualTrailingFlushScheduler()
        let controller = LiveActivityController(
            userEnabled: true,
            minUpdateInterval: 2,
            backend: backend,
            uptime: { now },
            flushScheduler: scheduler
        )

        controller.startOrUpdate(snapshot(title: "A"))
        await controller.waitForPendingOperations()
        XCTAssertEqual(backend.lastTitle, "A")

        now = 100.5
        controller.startOrUpdate(snapshot(title: "B"))
        await controller.waitForPendingOperations()
        XCTAssertEqual(backend.lastTitle, "A", "区间内的 B 暂不交付")
        XCTAssertNotNil(scheduler.scheduledAction, "必须安排一次尾随交付")
        XCTAssertEqual(scheduler.scheduledDelay ?? -1, 1.5, accuracy: 0.001)

        now = 102
        scheduler.fire()
        await controller.waitForPendingOperations()
        XCTAssertEqual(backend.lastTitle, "B", "无额外输入也必须交付尾随快照")
    }

    func testEndCancelsTrailingFlushWithoutRecreation() async {
        let backend = SpyLiveActivityBackend()
        var now: TimeInterval = 100
        let scheduler = ManualTrailingFlushScheduler()
        let controller = LiveActivityController(
            userEnabled: true,
            minUpdateInterval: 2,
            backend: backend,
            uptime: { now },
            flushScheduler: scheduler
        )

        controller.startOrUpdate(snapshot(title: "A"))
        await controller.waitForPendingOperations()
        now = 100.5
        controller.startOrUpdate(snapshot(title: "B"))
        await controller.waitForPendingOperations()
        XCTAssertEqual(backend.requestCount + backend.updateCount, 1)

        controller.end()
        await controller.waitForPendingOperations()
        XCTAssertGreaterThanOrEqual(scheduler.cancelCount, 1, "end 必须取消尾随交付")

        now = 102
        scheduler.fire()
        await controller.waitForPendingOperations()
        XCTAssertEqual(backend.requestCount + backend.updateCount, 1, "end 后尾随动作不得重建 / 追加")
        XCTAssertEqual(backend.endCount, 1)
    }

    func testEndSupersedesPendingUpdateAndPreventsLateRecreation() async {
        let backend = SpyLiveActivityBackend()
        var now: TimeInterval = 100
        let controller = LiveActivityController(
            userEnabled: true,
            minUpdateInterval: 0,
            backend: backend,
            uptime: { now }
        )

        controller.startOrUpdate(snapshot(title: "Pending"))
        controller.end()
        await controller.waitForPendingOperations()

        XCTAssertEqual(backend.requestCount, 0, "end 之前的待执行更新不得创建 Activity")
        XCTAssertEqual(backend.endCount, 1)

        now += 10
        controller.startOrUpdate(snapshot(title: "Late"))
        await controller.waitForPendingOperations()
        XCTAssertEqual(backend.requestCount, 0, "end 后不得被迟到更新重建")
        XCTAssertEqual(backend.updateCount, 0)
    }

    func testDisableEndsAndReenableRecovers() async {
        let backend = SpyLiveActivityBackend()
        let controller = LiveActivityController(userEnabled: true, minUpdateInterval: 0, backend: backend)

        controller.setUserEnabled(false)
        await controller.waitForPendingOperations()
        XCTAssertEqual(backend.endCount, 1)

        controller.setUserEnabled(true)
        controller.startOrUpdate(snapshot(title: "Again"))
        await controller.waitForPendingOperations()
        XCTAssertEqual(backend.requestCount, 1, "重新启用后应可再次创建")
    }

    func testProvidedStaleDateTracksTimestampBudget() async {
        let backend = SpyLiveActivityBackend()
        let timestamp = Date(timeIntervalSince1970: 2_000)
        let controller = LiveActivityController(userEnabled: true, minUpdateInterval: 0, backend: backend)

        controller.startOrUpdate(snapshot(timestamp: timestamp))
        await controller.waitForPendingOperations()

        let expected = timestamp.addingTimeInterval(RemoteActivityLimits.staleInterval)
        XCTAssertEqual(backend.staleDates.last ?? nil, expected as Date?)
    }

    func testUnauthorizedBackendDoesNotCreate() async {
        let backend = SpyLiveActivityBackend()
        backend.isAuthorized = false
        let controller = LiveActivityController(userEnabled: true, minUpdateInterval: 0, backend: backend)

        controller.startOrUpdate(snapshot())
        await controller.waitForPendingOperations()
        XCTAssertEqual(backend.requestCount, 0)
    }

    // MARK: - intent 反馈（F5）

    func testNewSongIdClearsOldMetadataWhenQueueUnavailable() {
        let oldDate = Date(timeIntervalSince1970: 500)
        let existing = state(title: "Old title", artist: "Old artist", songId: "1", lastUpdate: oldDate)
        let nowPlaying = NowPlayingResponse(songId: 2, paused: false, playing: false, buffering: true, position: 0, duration: 0, volume: 1)

        let updated = RemoteIntentFeedbackBuilder.makeState(
            existing: existing,
            status: nil,
            nowPlaying: nowPlaying,
            track: nil,
            authoritativeDate: nil
        )

        XCTAssertEqual(updated.songId, "2")
        XCTAssertEqual(updated.title, "", "新曲目且无元数据时必须清空旧标题")
        XCTAssertEqual(updated.artist, "", "新曲目且无元数据时必须清空旧艺人")
        XCTAssertEqual(updated.lastUpdate, oldDate, "刷新失败不得伪造新时间戳")
        XCTAssertFalse(updated.connectionAvailable)
        XCTAssertFalse(updated.isPlaying)
        XCTAssertTrue(updated.isBuffering)
    }

    func testRefreshFailureKeepsAuthoritativeTimestamp() {
        let oldDate = Date(timeIntervalSince1970: 321)
        let existing = state(lastUpdate: oldDate)

        let updated = RemoteIntentFeedbackBuilder.makeState(
            existing: existing,
            status: nil,
            nowPlaying: nil,
            track: nil,
            authoritativeDate: nil
        )

        XCTAssertEqual(updated.lastUpdate, oldDate)
        XCTAssertFalse(updated.connectionAvailable)
    }

    /// R4：命令后只拿到 status（拿不到 now-playing 身份）时，不得把旧曲目标为刚更新。
    func testStatusOnlyRefreshDoesNotMarkOldTrackFresh() {
        let oldDate = Date(timeIntervalSince1970: 111)
        let existing = state(title: "Old title", artist: "Old artist", songId: "5", lastUpdate: oldDate, connectionAvailable: true)

        let updated = RemoteIntentFeedbackBuilder.makeState(
            existing: existing,
            status: StatusResponse(state: .playing, position: 0, duration: 0, volume: 1, isFinished: false),
            nowPlaying: nil,
            track: nil,
            authoritativeDate: nil
        )

        XCTAssertEqual(updated.songId, "5")
        XCTAssertEqual(updated.title, "Old title", "旧标题不得被冒充为刚确认")
        XCTAssertEqual(updated.lastUpdate, oldDate, "status-only 不得刷新时间戳")
        XCTAssertFalse(updated.connectionAvailable, "status-only 不得冒充新鲜连接")
        XCTAssertTrue(updated.isPlaying, "独立的播放状态字段仍可更新")
    }

    func testSuccessfulRefreshUsesAuthoritativeDateAndTrack() {
        let authoritative = Date(timeIntervalSince1970: 9_999)
        let existing = state(songId: "1")
        let nowPlaying = NowPlayingResponse(songId: 8, paused: false, playing: true, buffering: false, position: 0, duration: 0, volume: 1)
        let track = LanShareTrack(
            id: "8",
            source: "netease",
            title: "New title",
            artists: [LanShareArtist(id: "1", name: "New artist")],
            album: nil,
            durationMs: 0,
            coverURL: nil
        )

        let updated = RemoteIntentFeedbackBuilder.makeState(
            existing: existing,
            status: StatusResponse(state: .playing, position: 0, duration: 0, volume: 1, isFinished: false),
            nowPlaying: nowPlaying,
            track: track,
            authoritativeDate: authoritative
        )

        XCTAssertEqual(updated.songId, "8")
        XCTAssertEqual(updated.title, "New title")
        XCTAssertEqual(updated.artist, "New artist")
        XCTAssertEqual(updated.lastUpdate, authoritative)
        XCTAssertTrue(updated.connectionAvailable)
    }
}

@MainActor
final class SpyLiveActivityBackend: LiveActivityBackend {
    var isAuthorized = true
    private(set) var requestCount = 0
    private(set) var updateCount = 0
    private(set) var endCount = 0
    private(set) var staleDates: [Date?] = []
    private(set) var states: [RemoteActivityAttributes.ContentState] = []
    private var active = false

    var lastTitle: String? { states.last?.title }

    func hasActiveActivity() -> Bool { active }

    func update(state: RemoteActivityAttributes.ContentState, staleDate: Date?) async {
        updateCount += 1
        active = true
        staleDates.append(staleDate)
        states.append(state)
    }

    func request(state: RemoteActivityAttributes.ContentState, staleDate: Date?) async {
        requestCount += 1
        active = true
        staleDates.append(staleDate)
        states.append(state)
    }

    func endAll() async {
        endCount += 1
        active = false
    }
}

/// 可手动推进的尾随调度器：用于验证 deadline 交付与 end 取消，无需真实等待。
final class ManualTrailingFlushScheduler: TrailingFlushScheduling {
    private(set) var scheduledAction: (@MainActor () -> Void)?
    private(set) var scheduledDelay: TimeInterval?
    private(set) var cancelCount = 0

    final class Token: TrailingFlushToken {
        var onCancel: (() -> Void)?
        func cancel() { onCancel?() }
    }

    func schedule(after interval: TimeInterval, action: @escaping @MainActor () -> Void) -> TrailingFlushToken {
        scheduledAction = action
        scheduledDelay = interval
        let token = Token()
        token.onCancel = { [weak self] in self?.cancelCount += 1 }
        return token
    }

    @MainActor
    func fire() {
        let pending = scheduledAction
        scheduledAction = nil
        pending?()
    }
}
#endif
