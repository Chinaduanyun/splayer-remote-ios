import Foundation

/// 传给 Live Activity 的只读快照。
///
/// ⚠️ 只包含可公开展示的信息：**绝不**包含主机、端口、Token、原始 URL 或媒体地址。
struct RemoteActivitySnapshot: Equatable, Sendable {
    var title: String
    var artist: String
    var songId: String
    var isPlaying: Bool
    var isBuffering: Bool
    var connectionAvailable: Bool
    var timestamp: Date
}

/// Live Activity 展示预算。ActivityKit 内容载荷很小，必须保守截断。
enum RemoteActivityLimits {
    static let title = 120
    static let artist = 140
    static let songId = 64
    /// 超过该时长未刷新即由系统 / 视图标记为过期。
    static let staleInterval: TimeInterval = 60

    static func truncated(_ value: String, limit: Int) -> String {
        String(value.prefix(limit))
    }
}

/// Live Activity 呈现抽象：生产实现是 `LiveActivityController`，测试 / 无 ActivityKit 时用空实现。
protocol LiveActivityPresenting: AnyObject {
    var areActivitiesEnabled: Bool { get }
    func startOrUpdate(_ snapshot: RemoteActivitySnapshot)
    func end()
    func setUserEnabled(_ enabled: Bool)
}

/// 空实现：不启动任何 Activity，只忠实汇报「不可用」。
final class NoopLiveActivityPresenter: LiveActivityPresenting {
    var areActivitiesEnabled: Bool { false }
    func startOrUpdate(_ snapshot: RemoteActivitySnapshot) {}
    func end() {}
    func setUserEnabled(_ enabled: Bool) {}
}
