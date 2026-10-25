import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// 交互式 Live Activity intent 的 **App 进程** 实现。
///
/// 安全与稳健：
/// - 只在此进程读取钥匙串 Token 与已保存的 host/port；扩展进程没有任何凭据路径；
/// - 一次 intent 只发起**一次**有界 HTTP 命令（8s 超时），绝不自动重试 / 重放；
/// - 无有效配置或设备锁定时，不发起请求，只把 Activity 标记为「连接不可用」，
///   提示用户回到 App 内完成连接（返回错误语义的友好降级）；
/// - 命令完成后尽力拉取一次最新状态来刷新 Activity，不承诺后台常驻连接。
enum RemoteIntentCommandExecutor {

    static func perform(rawCommand: String) async {
        guard let command = RemoteCommand(rawValue: rawCommand) else { return }
        let acquired = await RemoteIntentGate.shared.acquire()
        guard acquired else { return }

        guard let credentials = RemoteIntentCredentials.load() else {
            await RemoteIntentFeedback.markConnectionUnavailable()
            await RemoteIntentGate.shared.release()
            return
        }

        let client = RemoteAPIClient(baseURL: credentials.baseURL, token: credentials.token)
        do {
            try await client.send(command: command)
            if let status = try? await client.fetchStatus() {
                await RemoteIntentFeedback.apply(status)
            }
        } catch {
            await RemoteIntentFeedback.markConnectionUnavailable()
        }
        await RemoteIntentGate.shared.release()
    }
}

/// 串行去重：同一时刻只允许一个 intent 命令在途，避免连点造成的重复请求。
actor RemoteIntentGate {
    static let shared = RemoteIntentGate()
    private var busy = false

    func acquire() -> Bool {
        if busy { return false }
        busy = true
        return true
    }

    func release() {
        busy = false
    }
}

/// 从 App 已保存的配置读取凭据（UserDefaults 中的 host/port + 钥匙串 Token）。
///
/// 只在 App 进程可达；扩展进程无法访问（也不应访问）。
struct RemoteIntentCredentials {
    let baseURL: URL
    let token: String

    static func load() -> RemoteIntentCredentials? {
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: SettingsStore.Keys.host) else { return nil }
        let port = defaults.integer(forKey: SettingsStore.Keys.port)
        guard port > 0, port <= 65535 else { return nil }
        guard let token = try? KeychainTokenStore().loadToken(),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let url = try? HostValidator.buildBaseURL(host: host, port: port) else { return nil }
        return RemoteIntentCredentials(baseURL: url, token: token)
    }
}

/// 命令完成后刷新所有 Activity 的内容状态（仍然只含展示字段，绝无凭据）。
enum RemoteIntentFeedback {

    static func apply(_ status: StatusResponse) async {
        for activity in Activity<RemoteActivityAttributes>.activities {
            var state = activity.contentState
            state.isPlaying = status.state == .playing
            state.isBuffering = status.state == .buffering
            state.connectionAvailable = true
            state.lastUpdate = Date()
            await activity.update(using: state)
        }
    }

    static func markConnectionUnavailable() async {
        for activity in Activity<RemoteActivityAttributes>.activities {
            var state = activity.contentState
            state.connectionAvailable = false
            state.lastUpdate = Date()
            await activity.update(using: state)
        }
    }
}

#endif
