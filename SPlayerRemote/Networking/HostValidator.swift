import Foundation

/// 校验用户填写的主机与端口，并构造安全的本地 HTTP 基础地址。
///
/// 安全要点（参见 IMPLEMENTATION.md）：
/// - 只接受“纯主机”表示（IPv4 / IPv6 / 主机名 / .local），不接受 scheme、路径、查询、片段或 userinfo；
/// - 端口范围 1...65535；
/// - 使用 `URLComponents` 构造 URL，避免字符串拼接导致的解析歧义；
/// - 任何非法输入都必须抛出错误，绝不“猜测性修正”。
enum HostValidator {

    enum ValidationError: Error, Equatable, LocalizedError {
        case empty
        case containsScheme
        case containsPathQueryFragment
        case containsUserInfo
        case invalidHost
        case invalidCharacter
        case invalidPort

        var errorDescription: String? {
            switch self {
            case .empty:
                return "主机不能为空。"
            case .containsScheme:
                return "请只填写主机名或 IP，不要包含 http:// 等协议前缀。"
            case .containsPathQueryFragment:
                return "主机中不能包含路径、查询参数或片段（/ ? #）。"
            case .containsUserInfo:
                return "主机中不能包含用户名或密码（@）。"
            case .invalidHost:
                return "主机格式无效，请输入 IPv4、IPv6、主机名或 .local 名称。"
            case .invalidCharacter:
                return "主机包含不允许的字符。"
            case .invalidPort:
                return "端口必须是 1...65535 之间的整数。"
            }
        }
    }

    static let defaultPort = 6688

    /// 将原始主机字符串规范化为可放入 URLComponents.host 的形式。
    /// IPv6 会去掉外层方括号并以小写返回；IPv4 / 主机名保持小写。
    static func normalizeHost(_ raw: String) throws -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw ValidationError.empty }

        if host.contains("://") { throw ValidationError.containsScheme }
        if host.contains("/") || host.contains("?") || host.contains("#") {
            throw ValidationError.containsPathQueryFragment
        }
        if host.contains("@") { throw ValidationError.containsUserInfo }

        // IPv6：允许带 [] 或裸地址。
        if host.contains(":") {
            let stripped = host.hasPrefix("[") && host.hasSuffix("]")
                ? String(host.dropFirst().dropLast())
                : host
            guard isValidIPv6(stripped) else { throw ValidationError.invalidHost }
            return stripped.lowercased()
        }

        // 其余情况先看是否是合法 IPv4，再退回到主机名校验。
        if isValidIPv4(host) { return host.lowercased() }

        guard isValidHostname(host) else { throw ValidationError.invalidHost }
        return host.lowercased()
    }

    /// 校验并规范化端口字符串。
    static func normalizePort(_ raw: String) throws -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed) else { throw ValidationError.invalidPort }
        return try normalizePort(value)
    }

    /// 校验端口数值。
    static func normalizePort(_ raw: Int) throws -> Int {
        guard (1...65535).contains(raw) else { throw ValidationError.invalidPort }
        return raw
    }

    /// 由已规范的 host/port 构造 `http://host:port/api/external` 基础地址。
    static func buildBaseURL(host: String, port: Int) throws -> URL {
        let normalizedHost = try normalizeHost(host)
        let normalizedPort = try normalizePort(port)

        var components = URLComponents()
        components.scheme = "http"
        components.host = normalizedHost
        components.port = normalizedPort
        components.path = "/api/external"
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        guard let url = components.url else { throw ValidationError.invalidHost }
        return url
    }

    // MARK: - 私有校验

    private static func isValidIPv4(_ host: String) -> Bool {
        var addr = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    private static func isValidIPv6(_ host: String) -> Bool {
        var addr = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }

    /// 宽松但安全的主机名校验：字母/数字/连字符组成标签，允许末尾点与 `.local`。
    private static func isValidHostname(_ host: String) -> Bool {
        guard host.count <= 253 else { return false }
        var trimmed = host
        if trimmed.hasSuffix(".") { trimmed = String(trimmed.dropLast()) }
        guard !trimmed.isEmpty else { return false }

        let labels = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            let allowed = label.allSatisfy { ch in
                ch.isLetter && ch.isASCII || ch.isNumber && ch.isASCII || ch == "-"
            }
            guard allowed else { return false }
            guard label.first != "-", label.last != "-" else { return false }
        }
        return true
    }
}
