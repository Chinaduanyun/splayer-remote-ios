import Foundation
import UIKit

/// 第三方封面 CDN 的专用图片加载器。
///
/// 安全约束（与 REST 客户端**彻底分离**）：
/// - 使用**独立** `URLSession`，绝不携带 Token / 自定义请求头 / Cookie；
/// - 只接受 http / https 地址（`LanShareTrack` 已在解码时校验），其它一律拒绝；
/// - 拒绝 HTTP 重定向，避免请求被转发到非预期主机；
/// - 仅请求封面图片 URL；绝不使用 `nowPlaying.src` 等媒体流地址。
final class CoverImageLoader {

    static let shared = CoverImageLoader()

    private let session: URLSession
    private let ownsSession: Bool
    private let cache = NSCache<NSURL, UIImage>()
    private let lock = NSLock()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            self.session = CoverImageLoader.makeDefaultSession()
            self.ownsSession = true
        }
        cache.countLimit = 64
    }

    /// 生产用会话：无 Cookie、无附加头、拒绝重定向。
    static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = nil
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration, delegate: CoverRedirectDenyingDelegate(), delegateQueue: nil)
    }

    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// 加载并缓存封面；失败 / 非法地址返回 `nil`，由 UI 显示占位符。
    func image(for url: URL) async -> UIImage? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        if let cached = cache.object(forKey: url as NSURL) { return cached }

        lock.lock()
        if let existing = inFlight[url] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            defer { self.clearInFlight(url) }
            do {
                let (data, response) = try await self.session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    return nil
                }
                guard let image = UIImage(data: data) else { return nil }
                self.cache.setObject(image, forKey: url as NSURL)
                return image
            } catch {
                return nil
            }
        }
        inFlight[url] = task
        lock.unlock()
        return await task.value
    }

    private func clearInFlight(_ url: URL) {
        lock.lock()
        inFlight[url] = nil
        lock.unlock()
    }
}

/// 拒绝一切重定向的图片请求委托。
final class CoverRedirectDenyingDelegate: NSObject, URLSessionTaskDelegate {
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
