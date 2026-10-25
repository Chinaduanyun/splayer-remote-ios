import XCTest
@testable import SPlayerRemote

/// 封面加载安全：独立会话、绝不携带任何凭据（Token / 自定义头 / Cookie）。
final class CoverImageLoaderTests: XCTestCase {

    /// 1x1 PNG，用于让 `UIImage(data:)` 成功。
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    )!

    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testCoverRequestCarriesNoCredentials() async {
        var headers: [String: String] = [:]
        MockURLProtocol.setHandler { request in
            headers = request.allHTTPHeaderFields ?? [:]
            return (200, Self.onePixelPNG)
        }

        let loader = CoverImageLoader(session: TestSession.make())
        let image = await loader.image(for: URL(string: "https://cdn.example.invalid/cover.jpg")!)

        XCTAssertNotNil(image, "合法 PNG 应能解码")
        XCTAssertNil(headers["Authorization"], "封面请求绝不能带 Token")
        XCTAssertNil(headers["X-SPlayer-Token"], "封面请求绝不能带 Token")
        XCTAssertNil(headers["Cookie"], "封面请求绝不能带 Cookie")
        for key in headers.keys {
            XCTAssertFalse(key.lowercased().contains("splayer"), "不得出现自定义 SPlayer 头：\(key)")
        }
    }

    func testCoverLoaderRejectsNonHTTPURL() async {
        let loader = CoverImageLoader(session: TestSession.make())
        let image = await loader.image(for: URL(string: "file:///etc/passwd")!)
        XCTAssertNil(image)
    }

    func testCoverLoaderCachesSuccessfulImage() async {
        var callCount = 0
        MockURLProtocol.setHandler { _ in
            callCount += 1
            return (200, Self.onePixelPNG)
        }
        let loader = CoverImageLoader(session: TestSession.make())
        let url = URL(string: "https://cdn.example.invalid/cached.jpg")!
        _ = await loader.image(for: url)
        _ = await loader.image(for: url)
        XCTAssertEqual(callCount, 1, "相同 URL 第二次应命中缓存")
    }
}
