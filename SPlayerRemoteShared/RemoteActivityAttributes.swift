import ActivityKit
import AppIntents
import Foundation

/// Live Activity 的共享属性与内容状态。
///
/// 该文件被 **App target 与 Live Activity 扩展 target 共同编译**，因此两端使用同一套类型。
///
/// ⚠️ 内容状态**只允许**下列可公开展示字段：标题 / 艺人 / 歌曲 ID / 播放中 / 缓冲中 /
/// 最近更新时间 / 连接可用性。**绝不允许**放入主机、端口、Token、原始 URL 或媒体地址。
struct RemoteActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var songId: String
        var isPlaying: Bool
        var isBuffering: Bool
        var lastUpdate: Date
        var connectionAvailable: Bool
    }

    /// 静态属性：仅一个展示用途的名称。
    var activityName: String
}

/// 锁屏 / 灵动岛按钮可触发的命令集合。rawValue 与 `RemoteCommand` 对齐（上一曲为 `prev`）。
enum RemoteControlCommand: String, CaseIterable {
    case previous = "prev"
    case play
    case pause
    case next
}

/// 交互式 Live Activity 意图。
///
/// 采用 `LiveActivityIntent`：由系统在 **App 进程** 中执行，因此可以访问 App 的钥匙串与
/// 已保存配置；扩展进程绝不联网。`perform()` 只调用一次有界 HTTP 命令，不做重放 / 轮询。
struct RemoteControlIntent: LiveActivityIntent {

    static var title: LocalizedStringResource = "SPlayer 控制"
    static var description: IntentDescription? = IntentDescription("在锁屏或灵动岛控制 SPlayer 播放。")

    /// 命令 rawValue（`RemoteCommand` 的 rawValue）。非配置项，仅由控件构造。
    var command: String

    init() {
        command = ""
    }

    init(command: RemoteControlCommand) {
        self.command = command.rawValue
    }

    func perform() async throws -> some IntentResult {
        await RemoteIntentCommandExecutor.perform(rawCommand: command)
        return .result()
    }
}

#if !APP_TARGET
/// 扩展进程内的空实现。
///
/// 交互式 Live Activity 的 intent 由 App 进程执行，扩展二进制中的这一份**永远不会被调用**；
/// 它刻意不做任何事，也不谎报成功，从而保证扩展侧绝不发起网络请求。
enum RemoteIntentCommandExecutor {
    static func perform(rawCommand: String) async {}
}
#endif
