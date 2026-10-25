import Foundation
import Combine

/// 用户设置的持久化：只把 **host/port** 写入 `UserDefaults`；
/// Token 永远只存 Keychain（见 `KeychainTokenStore`），不落盘到 UserDefaults / 明文文件。
final class SettingsStore: ObservableObject {

    @Published var host: String
    @Published var portText: String
    @Published var token: String
    /// 上一次 Keychain 操作失败信息（若有）。
    @Published private(set) var keychainError: String?

    private let defaults: UserDefaults
    private let tokenStore: TokenStoring

    enum Keys {
        static let host = "remote.host"
        static let port = "remote.port"
    }

    init(defaults: UserDefaults = .standard, tokenStore: TokenStoring = KeychainTokenStore()) {
        self.defaults = defaults
        self.tokenStore = tokenStore

        self.host = defaults.string(forKey: Keys.host) ?? ""
        let storedPort = defaults.integer(forKey: Keys.port)
        self.portText = storedPort > 0 ? String(storedPort) : String(HostValidator.defaultPort)

        if let loaded = try? tokenStore.loadToken() {
            self.token = loaded
        } else {
            self.token = ""
        }
    }

    /// 持久化 host/port；忽略空白。
    func persistConnectionSettings() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmedHost, forKey: Keys.host)
        if let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) {
            defaults.set(port, forKey: Keys.port)
        }
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
