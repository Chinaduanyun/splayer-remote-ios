import Foundation

/// 构造发往 SPlayer 外部 API 的 `URLRequest`。
/// 独立成类型以便对「请求契约」做单元测试（方法、路径、头部、请求体）。
enum APIRequestFactory {

    /// 上游 REST 基础路径。baseURL 已包含该前缀。
    static let pathPrefix = "/api/external"

    /// 局域网分享基础路径（由同一个连接主机 + 端口派生）。
    static let lanSharePathPrefix = "/api/lanShare"

    /// 通用请求构造。
    /// - 注意：Token 只放在请求头，绝不写入 URL / 查询参数，避免进入日志或重定向。
    static func makeRequest(
        baseURL: URL,
        path: String,
        method: String,
        token: String,
        body: Data? = nil
    ) -> URLRequest {
        var url = baseURL
        if !path.isEmpty {
            url = url.appendingPathComponent(path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
            request.setValue(trimmedToken, forHTTPHeaderField: "X-SPlayer-Token")
        }

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func info(baseURL: URL, token: String) -> URLRequest {
        makeRequest(baseURL: baseURL, path: "info", method: "GET", token: token)
    }

    static func status(baseURL: URL, token: String) -> URLRequest {
        makeRequest(baseURL: baseURL, path: "status", method: "GET", token: token)
    }

    static func nowPlaying(baseURL: URL, token: String) -> URLRequest {
        makeRequest(baseURL: baseURL, path: "now-playing", method: "GET", token: token)
    }

    static func command(_ command: RemoteCommand, baseURL: URL, token: String) -> URLRequest {
        makeRequest(baseURL: baseURL, path: command.rawValue, method: "POST", token: token)
    }

    static func seek(positionMs: Int, baseURL: URL, token: String) throws -> URLRequest {
        let body = try jsonBody(["positionMs": positionMs])
        return makeRequest(baseURL: baseURL, path: "seek", method: "POST", token: token, body: body)
    }

    static func volume(_ volume: Double, baseURL: URL, token: String) throws -> URLRequest {
        let body = try jsonBody(["volume": volume])
        return makeRequest(baseURL: baseURL, path: "volume", method: "POST", token: token, body: body)
    }

    /// 局域网分享请求：复用**同一次连接捕获的基础地址**（主机 + 端口），
    /// 仅通过 `URLComponents` 替换路径，绝不重新读取编辑中的设置，也绝不改变 scheme / host / port。
    ///
    /// 与 REST 相同：Token 只放请求头、禁用 Cookie、调用方负责拒绝重定向。
    static func lanShareRequest(baseURL: URL, endpoint: String, token: String) -> URLRequest? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "\(lanSharePathPrefix)/\(endpoint)"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
            request.setValue(trimmedToken, forHTTPHeaderField: "X-SPlayer-Token")
        }
        return request
    }

    /// 稳定的 JSON 编码（sortedKeys）便于测试与阅读。
    static func jsonBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
