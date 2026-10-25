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
        /// 不透明的随机会话标识（**不是**凭据）：用于让命令反馈只更新属于当前授权会话的
        /// Activity，绝不包含主机 / Token / URL。默认空串以兼容旧内容。
        var sessionID: String = ""
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

/// Intent 执行失败的友好错误。
///
/// 由 `perform()` 抛出，AppIntents 会把 `errorDescription` 反馈给系统；
/// 扩展进程的 fallback 也抛错，绝不静默返回成功。
enum RemoteActivityCommandError: LocalizedError, Equatable {
    case extensionUnavailable
    case invalidCommand
    case noAuthorizedSession
    case deliveryFailed

    var errorDescription: String? {
        switch self {
        case .extensionUnavailable:
            return "请在 SPlayer 遥控器 App 内使用锁屏控制。"
        case .invalidCommand:
            return "无法识别的播放命令。"
        case .noAuthorizedSession:
            return "请先在 App 内连接 SPlayer，再使用锁屏控制。"
        case .deliveryFailed:
            return "无法连接到 SPlayer，请打开 App 检查连接。"
        }
    }
}

/// 交互式 Live Activity 意图。
///
/// 采用 `LiveActivityIntent`：由系统在 **App 进程** 中执行，因此可以访问 App 内存中的
/// 已授权会话；扩展进程绝不联网。
///
/// `command` 必须是 `@Parameter`：AppIntents 在重建 intent 时通过参数序列化传递值，
/// 仅靠初始化器赋值的普通属性无法作为可靠传输契约。
struct RemoteControlIntent: LiveActivityIntent {

    static var title: LocalizedStringResource = "SPlayer 控制"
    static var description: IntentDescription? = IntentDescription("在锁屏或灵动岛控制 SPlayer 播放。")

    @Parameter(title: "命令")
    var command: String

    init() {
        command = ""
    }

    init(command: RemoteControlCommand) {
        self.init()
        self.command = command.rawValue
    }

    func perform() async throws -> some IntentResult {
        // 失败会带友好错误抛给系统，绝不把未执行 / 失败当成成功。
        try await RemoteIntentCommandExecutor.perform(rawCommand: command)
        return .result()
    }
}

#if !APP_TARGET
/// 扩展进程内的 fallback。
///
/// 交互式 Live Activity 的 intent 由 App 进程执行，扩展二进制中的这一份**不执行任何网络操作**；
/// 它明确抛错（而不是返回成功），避免在意外被执行时谎报结果。
enum RemoteIntentCommandExecutor {
    static func perform(rawCommand: String) async throws {
        throw RemoteActivityCommandError.extensionUnavailable
    }
}
#endif
