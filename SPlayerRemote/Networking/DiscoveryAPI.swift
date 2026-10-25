import Foundation

struct DiscoveryCapabilities: Decodable {
    let protocolVersion: Int
    let serverSessionId: String
    let accountState: String
    let rendererReady: Bool
    let collabAuthorized: Bool
}
struct DiscoveryTrack: Decodable, Identifiable {
    struct Artist: Decodable { let name: String }
    let id: String
    let title: String
    let artists: [Artist]
    let coverUrl: String?
    var artwork: URL? { DiscoveryArtwork.sanitize(coverUrl) }
}
struct DiscoveryPlaylist: Decodable, Identifiable {
    let id: String
    let title: String
    let coverUrl: String?
    let trackCount: Int
}
struct DiscoverySelection: Decodable {
    let selectionId: UUID
    let expiresAt: Double
    let items: [DiscoveryTrack]
    let offset: Int
    let nextOffset: Int?
    let truncated: Bool
    func playable(index: Int, now: Date) -> Bool {
        items.count <= 100 && items.indices.contains(index) && expiresAt > now.timeIntervalSince1970 * 1000
    }
}
struct DiscoveryCommandStatus: Decodable {
    let commandId: UUID
    let state: String
    let result: ResultData?
    let error: String?
    struct ResultData: Decodable { let queueApplied: Bool; let playbackConfirmed: Bool; let selectedTrackId: String }
}
enum DiscoveryArtwork {
    static func sanitize(_ raw: String?) -> URL? {
        guard let raw, var c = URLComponents(string: raw), c.scheme == "https",
              c.user == nil, c.password == nil, c.port == nil,
              let host = c.host, host.hasSuffix(".music.126.net"),
              let number = Int(host.dropFirst().prefix(while: { $0.isNumber })),
              (1...99).contains(number), host == "p\(number).music.126.net" else { return nil }
        c.queryItems = [URLQueryItem(name: "param", value: "300y300")]
        c.fragment = nil
        return c.url
    }
}
struct DiscoveryFailure: Error {
    let status: Int
    let code: String
    var message: String {
        if status == 404 { return "需增强安卓版：官方旧版不支持发现；现有遥控仍可使用。" }
        switch code {
        case "FOREGROUND_REQUIRED": return "请将增强安卓版保持前台并等待播放器就绪。"
        case "ACCOUNT_REQUIRED": return "请先在 Android 登录账号。"
        case "ACCOUNT_NOT_READY": return "账号尚未就绪；心动推荐需要已有红心歌单和种子。"
        case "COLLAB_NOT_AUTHORIZED": return "请在 Android 开启共享、协作并授权此 iPhone。"
        case "UNAUTHORIZED": return "Token 无效，请检查连接设置。"
        case "SESSION_CHANGED": return "会话已变更，结果未知。不会重新提交。"
        default: return "发现暂不可用（\(status)）；请检查 Android 前台、登录及授权状态。"
        }
    }
}
protocol DiscoveryAPI {
    func get<T: Decodable>(_ path: String, query: [URLQueryItem], as: T.Type) async throws -> T
    func submit(session: String, selection: UUID, index: Int, command: UUID) async throws -> DiscoveryCommandStatus
}
final class DiscoveryAPIClient: DiscoveryAPI {
    private let configuration: ConnectionConfiguration
    private let session: URLSession
    init(configuration: ConnectionConfiguration, session: URLSession = RemoteAPIClient.makeDefaultSession()) {
        self.configuration = configuration
        self.session = session
    }
    func request(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        var c = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)!
        c.path = "/api/remote/v1/" + path
        c.queryItems = query.isEmpty ? nil : query
        c.fragment = nil
        var r = URLRequest(url: c.url!)
        r.httpMethod = body == nil ? "GET" : "POST"
        r.httpShouldHandleCookies = false
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.timeoutInterval = 8
        r.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }
        return r
    }
    private struct Envelope<T: Decodable>: Decodable { let ok: Bool; let data: T?; let error: ErrorData? }
    private struct ErrorData: Decodable { let code: String }
    private func execute<T: Decodable>(_ request: URLRequest, as: T.Type) async throws -> T {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DiscoveryFailure(status: 0, code: "") }
        let limit = 512 * 1024
        guard response.expectedContentLength <= Int64(limit) else { throw DiscoveryFailure(status: 413, code: "") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw DiscoveryFailure(status: 413, code: "") }
            data.append(byte)
        }
        let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data)
        guard (200..<300).contains(http.statusCode), envelope?.ok == true, let value = envelope?.data else {
            throw DiscoveryFailure(status: http.statusCode, code: envelope?.error?.code ?? "")
        }
        return value
    }
    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as: T.Type) async throws -> T {
        try await execute(request(path, query: query), as: T.self)
    }
    func submit(session: String, selection: UUID, index: Int, command: UUID) async throws -> DiscoveryCommandStatus {
        let body = try JSONSerialization.data(withJSONObject: ["commandId": command.uuidString, "serverSessionId": session, "action": "replaceQueue", "selectionId": selection.uuidString, "startIndex": index])
        // Exactly one attempt. A transport error may mean it was accepted; never retry this POST.
        return try await execute(request("commands", body: body), as: DiscoveryCommandStatus.self)
    }
}
