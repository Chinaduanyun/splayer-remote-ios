#if canImport(ActivityKit)
import XCTest
import Foundation
@testable import SPlayerRemote

/// Live Activity 控制器的有序性 / 限频 / end 语义，以及 intent 反馈的曲目与新鲜度规则。
@available(iOS 17.0, *)
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

        XCTAssertEqual(backend.requestCount + backend.updateCount, 1, "仅时间戳变化的爆发应被限频")
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

final class SpyLiveActivityBackend: LiveActivityBackend {
    var isAuthorized = true
    private(set) var requestCount = 0
    private(set) var updateCount = 0
    private(set) var endCount = 0
    private(set) var staleDates: [Date?] = []
    private var active = false

    func hasActiveActivity() -> Bool { active }

    func update(state: RemoteActivityAttributes.ContentState, staleDate: Date?) async {
        updateCount += 1
        active = true
        staleDates.append(staleDate)
    }

    func request(state: RemoteActivityAttributes.ContentState, staleDate: Date?) async {
        requestCount += 1
        active = true
        staleDates.append(staleDate)
    }

    func endAll() async {
        endCount += 1
        active = false
    }
}
#endif
