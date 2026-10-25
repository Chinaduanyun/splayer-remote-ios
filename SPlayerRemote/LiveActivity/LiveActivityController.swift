import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// 尾随交付的可取消句柄。
protocol TrailingFlushToken: AnyObject {
    func cancel()
}

/// 尾随交付调度器：生产使用 `Task.sleep`；测试可注入手动调度器，确定性地推进到 deadline。
protocol TrailingFlushScheduling: AnyObject {
    func schedule(after interval: TimeInterval, action: @escaping @MainActor () -> Void) -> TrailingFlushToken
}

/// 生产调度器：延迟 interval 秒后在 MainActor 执行 action，可取消。
final class TaskTrailingFlushScheduler: TrailingFlushScheduling {
    func schedule(after interval: TimeInterval, action: @escaping @MainActor () -> Void) -> TrailingFlushToken {
        let clamped = min(max(0, interval), 3_600)
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
        return TaskTrailingFlushToken(task: task)
    }
}

final class TaskTrailingFlushToken: TrailingFlushToken {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

/// Live Activity 的后端抽象：生产使用 ActivityKit；测试注入记录型替身。
/// 所有生命周期状态隔离在 MainActor，避免与视图 / ViewModel 的写入竞争。
@MainActor
protocol LiveActivityBackend: AnyObject {
    var isAuthorized: Bool { get }
    func hasActiveActivity() -> Bool
    func update(state: RemoteActivityAttributes.ContentState, staleDate: Date?) async
    func request(state: RemoteActivityAttributes.ContentState, staleDate: Date?) async
    func endAll() async
}

@available(iOS 17.0, *)
@MainActor
final class ActivityKitLiveActivityBackend: LiveActivityBackend {
    nonisolated init() {}

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
/// - 生命周期状态（世代 / 结束标志 / 开关 / 任务链）全部隔离在 MainActor：
///   非隔离方法里创建的 `Task` 不会继承调用方的 actor，因此这里统一 @MainActor；
/// - 所有 ActivityKit 生命周期操作通过**有序任务链**串行执行，`end()` 递增世代并排在末尾，
///   因此 end 之后不会再有更早的 update 重建 Activity；
/// - 限频：区间内只保留最新快照（合幷突发更新），但播放 / 缓冲 / 连接可用性等
///   生命周期变化立即交付；重复心跳则按区间续期，避免锁屏数据被无界刷新或长期过期。
@available(iOS 17.0, *)
@MainActor
final class LiveActivityController: LiveActivityPresenting {

    private let backend: LiveActivityBackend
    private let minUpdateInterval: TimeInterval
    private let staleInterval: TimeInterval
    private let uptime: () -> TimeInterval
    private let flushScheduler: TrailingFlushScheduling

    private var userEnabled: Bool
    private var ended = false
    private var generation = 0
    private var operationTask: Task<Void, Never>?
    private var lastKey: ActivityContentKey?
    private var lastUpdateUptime: TimeInterval = 0
    /// 区间内被抑制的最新快照；在 deadline 交付，无额外输入也不会丢失。
    private var pendingSnapshot: RemoteActivitySnapshot?
    private var trailingFlushToken: TrailingFlushToken?

    nonisolated init(
        userEnabled: Bool = false,
        minUpdateInterval: TimeInterval = 2,
        staleInterval: TimeInterval = RemoteActivityLimits.staleInterval,
        backend: LiveActivityBackend? = nil,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        flushScheduler: TrailingFlushScheduling = TaskTrailingFlushScheduler()
    ) {
        self.backend = backend ?? ActivityKitLiveActivityBackend()
        self.userEnabled = userEnabled
        self.minUpdateInterval = minUpdateInterval
        self.staleInterval = staleInterval
        self.uptime = uptime
        self.flushScheduler = flushScheduler
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

        // 生命周期相关变化（播放 / 缓冲 / 连接可用性）必须立即交付，避免锁屏控件滞后。
        let lifecycleChanged = key.isPlaying != lastKey?.isPlaying
            || key.isBuffering != lastKey?.isBuffering
            || key.connectionAvailable != lastKey?.connectionAvailable

        if !lifecycleChanged, now - lastUpdateUptime < minUpdateInterval {
            // 合幷：保留最新被抑制的快照，并安排一次可取消的尾随交付，
            // 即使之后没有任何输入也能在区间边界交付最终状态。
            pendingSnapshot = snapshot
            scheduleTrailingFlushIfNeeded()
            return
        }
        deliver(snapshot, key: key, now: now)
    }

    func end() {
        ended = true
        generation += 1
        lastKey = nil
        lastUpdateUptime = 0
        cancelTrailingFlush()
        pendingSnapshot = nil
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

    /// 交付一个快照（立即），并取消可能存在的尾随交付。
    private func deliver(_ snapshot: RemoteActivitySnapshot, key: ActivityContentKey, now: TimeInterval) {
        cancelTrailingFlush()
        pendingSnapshot = nil
        lastKey = key
        lastUpdateUptime = now
        let expectedGeneration = generation
        enqueue { [weak self] in
            guard let self, self.generation == expectedGeneration, self.userEnabled, !self.ended else { return }
            await self.apply(snapshot)
        }
    }

    /// 为最新被抑制的快照安排一次尾随交付（已安排则不重复）。
    private func scheduleTrailingFlushIfNeeded() {
        guard trailingFlushToken == nil else { return }
        let remaining = max(0, minUpdateInterval - max(0, uptime() - lastUpdateUptime))
        let generationAtSchedule = generation
        trailingFlushToken = flushScheduler.schedule(after: remaining, action: { [weak self] in
            guard let self,
                  self.generation == generationAtSchedule,
                  self.userEnabled,
                  !self.ended,
                  let pending = self.pendingSnapshot else { return }
            self.trailingFlushToken = nil
            self.deliver(pending, key: ActivityContentKey(snapshot: pending), now: self.uptime())
        })
    }

    private func cancelTrailingFlush() {
        trailingFlushToken?.cancel()
        trailingFlushToken = nil
    }

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
    let sessionID: String

    init(snapshot: RemoteActivitySnapshot) {
        title = RemoteActivityLimits.truncated(snapshot.title, limit: RemoteActivityLimits.title)
        artist = RemoteActivityLimits.truncated(snapshot.artist, limit: RemoteActivityLimits.artist)
        songId = RemoteActivityLimits.truncated(snapshot.songId, limit: RemoteActivityLimits.songId)
        isPlaying = snapshot.isPlaying
        isBuffering = snapshot.isBuffering
        connectionAvailable = snapshot.connectionAvailable
        sessionID = RemoteActivityLimits.truncated(snapshot.sessionID, limit: RemoteActivityLimits.sessionId)
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
            connectionAvailable: snapshot.connectionAvailable,
            sessionID: RemoteActivityLimits.truncated(snapshot.sessionID, limit: RemoteActivityLimits.sessionId)
        )
    }
}

#endif
