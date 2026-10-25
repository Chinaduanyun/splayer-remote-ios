import Foundation

/// 远端控制抽象，便于在测试中注入 mock。
protocol RemoteAPI {
    func fetchInfo() async throws -> InfoResponse
    func fetchStatus() async throws -> StatusResponse
    func fetchNowPlaying() async throws -> NowPlayingResponse
    func send(command: RemoteCommand) async throws
    func seek(positionMs: Int) async throws
    func setVolume(_ volume: Double) async throws
}

/// 基于 URLSession 的 SPlayer 外部 API 客户端。
///
/// - 拒绝 HTTP 重定向（防止携带 Token 的请求被转发到其它主机）；
/// - 统一的错误映射（401/403/网络/解码）；
/// - 请求之间彼此独立，调用方负责避免并发重叠。
final class RemoteAPIClient: RemoteAPI {

    let baseURL: URL
    let token: String
    private let session: URLSession

    init(baseURL: URL, token: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.session = session ?? RemoteAPIClient.makeDefaultSession()
    }

    /// 生产用会话：短超时 + 禁用 Cookie + 拒绝重定向。
    static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: RedirectDenyingDelegate(), delegateQueue: nil)
    }

    // MARK: - RemoteAPI

    func fetchInfo() async throws -> InfoResponse {
        let data = try await perform(APIRequestFactory.info(baseURL: baseURL, token: token))
        return try decode(InfoResponse.self, from: data)
    }

    func fetchStatus() async throws -> StatusResponse {
        let data = try await perform(APIRequestFactory.status(baseURL: baseURL, token: token))
        return try decode(StatusResponse.self, from: data)
    }

    func fetchNowPlaying() async throws -> NowPlayingResponse {
        let data = try await perform(APIRequestFactory.nowPlaying(baseURL: baseURL, token: token))
        return try decode(NowPlayingResponse.self, from: data)
    }

    func send(command: RemoteCommand) async throws {
        let data = try await perform(APIRequestFactory.command(command, baseURL: baseURL, token: token))
        try requireAcknowledgement(data)
    }

    func seek(positionMs: Int) async throws {
        guard positionMs >= 0 else {
            throw RemoteAPIError.invalidConfiguration("跳转位置必须大于等于 0。")
        }
        let request = try APIRequestFactory.seek(positionMs: positionMs, baseURL: baseURL, token: token)
        let data = try await perform(request)
        try requireAcknowledgement(data)
    }

    func setVolume(_ volume: Double) async throws {
        guard volume.isFinite else {
            throw RemoteAPIError.invalidConfiguration("音量必须是有限数值。")
        }
        let clamped = min(max(volume, 0), 1)
        let request = try APIRequestFactory.volume(clamped, baseURL: baseURL, token: token)
        let data = try await perform(request)
        try requireAcknowledgement(data)
    }

    // MARK: - 内部

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw RemoteAPIError.cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw RemoteAPIError.cancelled
        } catch {
            throw RemoteAPIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RemoteAPIError.transport("非 HTTP 响应。")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw RemoteAPIError.unauthorized
        case 403:
            throw RemoteAPIError.forbidden
        default:
            throw RemoteAPIError.httpStatus(http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteAPIError.decoding
        }
    }

    /// 控制类接口（play/pause/stop/next/prev/seek/volume）必须显式返回 `{ok:true}`。
    /// 仅凭 2xx 不能认定操作被接受。
    private func requireAcknowledgement(_ data: Data) throws {
        guard let ack = try? JSONDecoder().decode(CommandAcknowledgement.self, from: data), ack.ok else {
            throw RemoteAPIError.unexpectedResponse
        }
    }
}

/// 上游控制类接口的成功响应体：`{ "ok": true }`。
private struct CommandAcknowledgement: Decodable {
    let ok: Bool
}

/// 拒绝一切 HTTP 重定向：返回 nil 后 URLSession 会把 3xx 原样返回给调用方，
/// 由 `perform` 转成 httpStatus 错误。这样 Token 永远不会被转发到重定向目标。
final class RedirectDenyingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
