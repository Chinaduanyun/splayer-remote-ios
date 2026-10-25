import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Live Activity 的后端抽象：生产使用 ActivityKit；测试注入记录型替身。
protocol LiveActivityBackend: AnyObject {
    var isAuthorized: Bool { get }
    func hasActiveActivity() -> Bool
    func update(state: RemoteActivityAttributes.ContentState, staleDate: Date?) async
    func request(state: RemoteActivityAttributes.ContentState, staleDate: Date?) async
    func endAll() async
}

@available(iOS 17.0, *)
final class ActivityKitLiveActivityBackend: LiveActivityBackend {
    var isAuthorized: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func hasActiveActivity() -> Bool {
        !Activity<RemoteActivityAttributes>.activities.isEmpty
    }

    func update(state: RemoteActivityAttributes.ContentState, staleDate: Date?) async {
        let content = ActivityContent(state: state, staleDate: staleDate)
        for activity in Activity<RemoteActivityAttributes>.activities {
            await activity.update(content)
        }
    }

    func request(state: RemoteActivityAttributes.ContentState, staleDate: Date?) async {
        let attributes = RemoteActivityAttributes(activityName: "SPlayer 播放")
        let content = ActivityContent(state: state, staleDate: staleDate)
        _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    func endAll() async {
        for activity in Activity<RemoteActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

/// 生产 Live Activity 控制器（iOS 17+）。
///
/// - 用户显式开关 + `ActivityAuthorizationInfo` 双重门控；
/// - 所有 ActivityKit 生命周期操作通过**有序任务链**串行执行，`end()` 递增世代并排在末尾，
///   因此 end 之后不会再有更早的 update 重建 Activity；
/// - 限频比较**排除时间戳**（只比较展示内容），避免每个 WS tick 都更新；
/// - 内容带 `staleDate`，过期后由系统 / 视图标记为不新鲜。
@available(iOS 17.0, *)
final class LiveActivityController: LiveActivityPresenting {

    private let backend: LiveActivityBackend
    private let minUpdateInterval: TimeInterval
    private let staleInterval: TimeInterval
    private let uptime: () -> TimeInterval

    private var userEnabled: Bool
    private var ended = false
    private var generation = 0
    private var operationTask: Task<Void, Never>?
    private var lastKey: ActivityContentKey?
    private var lastUpdateUptime: TimeInterval = 0

    init(
        userEnabled: Bool = false,
        minUpdateInterval: TimeInterval = 2,
        staleInterval: TimeInterval = RemoteActivityLimits.staleInterval,
        backend: LiveActivityBackend? = nil,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.backend = backend ?? ActivityKitLiveActivityBackend()
        self.userEnabled = userEnabled
        self.minUpdateInterval = minUpdateInterval
        self.staleInterval = staleInterval
        self.uptime = uptime
    }

    var areActivitiesEnabled: Bool { backend.isAuthorized }

    func setUserEnabled(_ enabled: Bool) {
        userEnabled = enabled
        if enabled {
            ended = false
            lastKey = nil
        } else {
            end()
        }
    }

    func startOrUpdate(_ snapshot: RemoteActivitySnapshot) {
        guard userEnabled, !ended, backend.isAuthorized else { return }

        let key = ActivityContentKey(snapshot: snapshot)
        let now = uptime()
        if key == lastKey, now - lastUpdateUptime < minUpdateInterval {
            return
        }
        lastKey = key
        lastUpdateUptime = now

        let expectedGeneration = generation
        enqueue { [weak self] in
            guard let self, self.generation == expectedGeneration, self.userEnabled, !self.ended else { return }
            await self.apply(snapshot)
        }
    }

    func end() {
        ended = true
        generation += 1
        lastKey = nil
        lastUpdateUptime = 0
        let expectedGeneration = generation
        enqueue { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            await self.backend.endAll()
        }
    }

    /// 测试支持：等待当前有序任务链完成。
    func waitForPendingOperations() async {
        await operationTask?.value
    }

    // MARK: - 内部

    private func apply(_ snapshot: RemoteActivitySnapshot) async {
        let state = RemoteActivityAttributes.ContentState(snapshot: snapshot)
        let staleDate = snapshot.timestamp.addingTimeInterval(staleInterval)
        if backend.hasActiveActivity() {
            await backend.update(state: state, staleDate: staleDate)
        } else {
            await backend.request(state: state, staleDate: staleDate)
        }
    }

    /// 有序任务链：每个操作等待前一个完成；旧世代操作在执行前被丢弃。
    private func enqueue(_ operation: @escaping () async -> Void) {
        let previous = operationTask
        operationTask = Task {
            _ = await previous?.value
            await operation()
        }
    }
}

/// 仅用于限频比较的展示内容键（**排除**时间戳）。
private struct ActivityContentKey: Equatable {
    let title: String
    let artist: String
    let songId: String
    let isPlaying: Bool
    let isBuffering: Bool
    let connectionAvailable: Bool

    init(snapshot: RemoteActivitySnapshot) {
        title = RemoteActivityLimits.truncated(snapshot.title, limit: RemoteActivityLimits.title)
        artist = RemoteActivityLimits.truncated(snapshot.artist, limit: RemoteActivityLimits.artist)
        songId = RemoteActivityLimits.truncated(snapshot.songId, limit: RemoteActivityLimits.songId)
        isPlaying = snapshot.isPlaying
        isBuffering = snapshot.isBuffering
        connectionAvailable = snapshot.connectionAvailable
    }
}

extension RemoteActivityAttributes.ContentState {
    /// 由只读快照构造 Activity 内容状态；快照不含任何凭据，字段按展示预算截断。
    init(snapshot: RemoteActivitySnapshot) {
        self.init(
            title: RemoteActivityLimits.truncated(snapshot.title, limit: RemoteActivityLimits.title),
            artist: RemoteActivityLimits.truncated(snapshot.artist, limit: RemoteActivityLimits.artist),
            songId: RemoteActivityLimits.truncated(snapshot.songId, limit: RemoteActivityLimits.songId),
            isPlaying: snapshot.isPlaying,
            isBuffering: snapshot.isBuffering,
            lastUpdate: snapshot.timestamp,
            connectionAvailable: snapshot.connectionAvailable
        )
    }
}

#endif
