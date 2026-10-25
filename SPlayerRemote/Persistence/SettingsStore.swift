import Foundation
import Combine

/// 一次连接所使用的**不可变**配置快照。
///
/// 连接建立时捕获，之后 REST 与所有 WebSocket 重试都复用同一份，
/// 绝不重新读取用户正在编辑的 `SettingsStore`，避免「REST 连 A、WS 连 B」的错位。
struct ConnectionConfiguration: Equatable {
    let baseURL: URL
    let host: String
    let port: Int
    let token: String
    let useWebSocket: Bool
}

/// 用户设置的持久化：只把 **host/port** 写入 `UserDefaults`；
/// Token 永远只存 Keychain（见 `KeychainTokenStore`），不落盘到 UserDefaults / 明文文件。
final class SettingsStore: ObservableObject {

    @Published var host: String
    @Published var portText: String
    @Published var token: String
    /// 是否启用实时 WebSocket（只读事件通道）。默认开启，但始终保留 HTTP 轮询回退。
    @Published var useWebSocket: Bool
    /// 是否在启动 / 回前台时自动连接（默认关闭，首次安装更安全）。
    @Published var autoConnect: Bool
    /// 上一次 Keychain 操作失败信息（若有）。
    @Published private(set) var keychainError: String?

    private let defaults: UserDefaults
    private let tokenStore: TokenStoring

    enum Keys {
        static let host = "remote.host"
        static let port = "remote.port"
        static let useWebSocket = "remote.useWebSocket"
        static let autoConnect = "remote.autoConnect"
    }

    init(defaults: UserDefaults = .standard, tokenStore: TokenStoring = KeychainTokenStore()) {
        self.defaults = defaults
        self.tokenStore = tokenStore

        self.host = defaults.string(forKey: Keys.host) ?? ""
        let storedPort = defaults.integer(forKey: Keys.port)
        self.portText = storedPort > 0 ? String(storedPort) : String(HostValidator.defaultPort)
        // 缺省视为开启（保留历史用户），但用户可关闭。
        self.useWebSocket = defaults.object(forKey: Keys.useWebSocket) as? Bool ?? true
        self.autoConnect = defaults.object(forKey: Keys.autoConnect) as? Bool ?? false

        if let loaded = try? tokenStore.loadToken() {
            self.token = loaded
        } else {
            self.token = ""
        }
    }

    /// 持久化 host/port 与连接偏好；忽略空白。
    func persistConnectionSettings() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmedHost, forKey: Keys.host)
        if let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) {
            defaults.set(port, forKey: Keys.port)
        }
        defaults.set(useWebSocket, forKey: Keys.useWebSocket)
        defaults.set(autoConnect, forKey: Keys.autoConnect)
    }

    /// 是否已保存可用的主机 + Token（使用**已提交**的配置，而非编辑中的草稿）。
    var hasSavedConnection: Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedToken.isEmpty else { return false }
        return (try? makeBaseURL()) != nil
    }

    /// 从**已提交**的设置构造不可变连接配置。
    func makeConfiguration() throws -> ConnectionConfiguration {
        let normalizedHost = try HostValidator.normalizeHost(host)
        let port = try HostValidator.normalizePort(portText)
        let url = try HostValidator.buildBaseURL(host: normalizedHost, port: port)
        return ConnectionConfiguration(
            baseURL: url,
            host: normalizedHost,
            port: port,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            useWebSocket: useWebSocket
        )
    }

    /// 原子保存：先写钥匙串，成功后再提交 host/port/token 偏好。
    /// 任一步失败都不改变已保存配置，避免把未保存的 host / Token 泄漏给重连或自动连接。
    func saveConfiguration(
        host newHost: String,
        portText newPortText: String,
        token newToken: String,
        useWebSocket newUseWebSocket: Bool,
        autoConnect newAutoConnect: Bool
    ) throws {
        let normalizedHost = try HostValidator.normalizeHost(newHost)
        let port = try HostValidator.normalizePort(newPortText)
        do {
            try tokenStore.save(token: newToken)
        } catch {
            keychainError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
        keychainError = nil
        host = normalizedHost
        portText = String(port)
        token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        useWebSocket = newUseWebSocket
        autoConnect = newAutoConnect
        defaults.set(normalizedHost, forKey: Keys.host)
        defaults.set(port, forKey: Keys.port)
        defaults.set(newUseWebSocket, forKey: Keys.useWebSocket)
        defaults.set(newAutoConnect, forKey: Keys.autoConnect)
    }

    /// 将 Token 写入 Keychain；失败时抛出并记录错误，保持输入不变以便用户重试。
    func persistToken() throws {
        do {
            try tokenStore.save(token: token)
            keychainError = nil
        } catch {
            keychainError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    func clearToken() throws {
        try tokenStore.deleteToken()
        token = ""
        keychainError = nil
    }

    /// 校验当前 host/port 并返回基础 URL。
    func makeBaseURL() throws -> URL {
        let normalizedHost = try HostValidator.normalizeHost(host)
        let port = try HostValidator.normalizePort(portText)
        return try HostValidator.buildBaseURL(host: normalizedHost, port: port)
    }
}
