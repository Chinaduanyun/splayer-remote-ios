import Foundation
import Security

/// Token 存储抽象：生产使用 Keychain，测试可注入内存实现。
protocol TokenStoring {
    func save(token: String) throws
    func loadToken() throws -> String?
    func deleteToken() throws
}

enum KeychainError: Error, Equatable, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "钥匙串操作失败（OSStatus \(status)），Token 未保存。"
        case .invalidData:
            return "钥匙串中存储的 Token 数据无法解析。"
        }
    }
}

/// 使用 `kSecClassGenericPassword` 将 Token 存入 Keychain。
/// - 可访问性为 `AfterFirstUnlockThisDeviceOnly`：仅本机、重启解锁后可用；
/// - 任何失败都抛出错误，调用方必须显式提示用户，绝不静默降级到明文存储。
struct KeychainTokenStore: TokenStoring {
    let service: String
    let account: String

    init(
        service: String = "com.example.splayerremote.token",
        account: String = "remoteAPIToken"
    ) {
        self.service = service
        self.account = account
    }

    func save(token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteToken()
            return
        }
        try deleteToken()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(trimmed.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func loadToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
