import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// 生产 Live Activity 控制器（iOS 17+）。
///
/// - 用户显式开关 + `ActivityAuthorizationInfo` 双重门控，权限不可用时优雅降级；
/// - 启动 / 更新在主线程调用，内部按时间 + 内容去重，避免每个轮询 tick 都更新；
/// - App 前台恢复时复用已存在的 Activity（不重复 request）；
/// - 断开 / 用户关闭时立即结束。
@available(iOS 17.0, *)
final class LiveActivityController: LiveActivityPresenting {

    private var userEnabled: Bool
    private var lastSnapshot: RemoteActivitySnapshot?
    private var lastUpdateUptime: TimeInterval = 0
    private let minUpdateInterval: TimeInterval
    private let uptime: () -> TimeInterval

    init(
        userEnabled: Bool = false,
        minUpdateInterval: TimeInterval = 2,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.userEnabled = userEnabled
        self.minUpdateInterval = minUpdateInterval
        self.uptime = uptime
    }

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func setUserEnabled(_ enabled: Bool) {
        userEnabled = enabled
        if !enabled { end() }
    }

    func startOrUpdate(_ snapshot: RemoteActivitySnapshot) {
        guard userEnabled, areActivitiesEnabled else { return }
        let now = uptime()
        if snapshot == lastSnapshot, now - lastUpdateUptime < minUpdateInterval { return }
        lastSnapshot = snapshot
        lastUpdateUptime = now
        let state = RemoteActivityAttributes.ContentState(snapshot: snapshot)
        Task { await Self.apply(state) }
    }

    func end() {
        lastSnapshot = nil
        lastUpdateUptime = 0
        Task { await Self.endAll() }
    }

    // MARK: - ActivityKit

    private static func apply(_ state: RemoteActivityAttributes.ContentState) async {
        if let existing = Activity<RemoteActivityAttributes>.activities.first {
            await existing.update(using: state)
            return
        }
        let attributes = RemoteActivityAttributes(activityName: "SPlayer 播放")
        do {
            _ = try Activity.request(attributes: attributes, contentState: state, pushType: nil)
        } catch {
            // 权限 / 频率限制等失败：静默忽略，绝不影响 App 主流程。
        }
    }

    private static func endAll() async {
        for activity in Activity<RemoteActivityAttributes>.activities {
            await activity.end(using: nil, dismissalPolicy: .immediate)
        }
    }
}

extension RemoteActivityAttributes.ContentState {
    /// 由只读快照构造 Activity 内容状态；快照不含任何凭据。
    init(snapshot: RemoteActivitySnapshot) {
        self.init(
            title: snapshot.title,
            artist: snapshot.artist,
            songId: snapshot.songId,
            isPlaying: snapshot.isPlaying,
            isBuffering: snapshot.isBuffering,
            lastUpdate: snapshot.timestamp,
            connectionAvailable: snapshot.connectionAvailable
        )
    }
}

#endif
