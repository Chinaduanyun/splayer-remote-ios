import XCTest
@testable import SPlayerRemote

final class RequestEncodingTests: XCTestCase {

    private let baseURL = URL(string: "http://192.168.31.100:6688/api/external")!

    func testGetRequestShapeAndHeaders() throws {
        let request = APIRequestFactory.status(baseURL: baseURL, token: "secret-token")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.31.100:6688/api/external/status")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SPlayer-Token"), "secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.httpBody)
    }

    func testTokenNeverAppearsInURL() {
        let request = APIRequestFactory.info(baseURL: baseURL, token: "secret-token")
        let urlString = request.url?.absoluteString ?? ""
        XCTAssertFalse(urlString.contains("secret-token"))
        XCTAssertFalse(urlString.contains("token="))
    }

    func testNoAuthHeadersWhenTokenBlank() {
        let request = APIRequestFactory.info(baseURL: baseURL, token: "   ")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-SPlayer-Token"))
    }

    func testCommandRequestsUsePostAndCorrectPaths() {
        for command in RemoteCommand.allCases {
            let request = APIRequestFactory.command(command, baseURL: baseURL, token: "t")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.lastPathComponent, command.rawValue)
        }
    }

    func testSeekBodyEncoding() throws {
        let request = try APIRequestFactory.seek(positionMs: 60000, baseURL: baseURL, token: "t")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.lastPathComponent, "seek")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["positionMs"] as? Int, 60000)
    }

    func testVolumeBodyEncoding() throws {
        let request = try APIRequestFactory.volume(0.25, baseURL: baseURL, token: "t")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.lastPathComponent, "volume")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["volume"] as? Double, 0.25)
    }

    func testJSONBodyIsSortedAndStable() throws {
        let data = try APIRequestFactory.jsonBody(["b": 1, "a": 2])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"a":2,"b":1}"#)
    }

    // MARK: - 局域网分享请求（同一次连接捕获的主机 + 端口，路径替换）

    func testLanShareRequestReplacesPathKeepsHostPort() throws {
        let request = try XCTUnwrap(APIRequestFactory.lanShareRequest(baseURL: baseURL, endpoint: "getQueue", token: "secret-token"))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "http://192.168.31.100:6688/api/lanShare/getQueue")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertFalse((request.url?.absoluteString ?? "").contains("secret-token"))
    }

    func testLanShareRequestHandlesIPv6Host() throws {
        let ipv6Base = URL(string: "http://[fe80::1]:6688/api/external")!
        let request = try XCTUnwrap(APIRequestFactory.lanShareRequest(baseURL: ipv6Base, endpoint: "getLyric", token: "t"))
        XCTAssertEqual(request.url?.path, "/api/lanShare/getLyric")
        XCTAssertEqual(request.url?.port, 6688)
        XCTAssertEqual(request.url?.host, "fe80::1")
    }

    // MARK: - 协作控制 WS（唯一经批准的查询串 token 例外）

    func testCollaborationWebSocketUsesReceiverPathAndQueryToken() throws {
        let request = try XCTUnwrap(APIRequestFactory.collaborationWebSocketRequest(baseURL: baseURL, wsToken: "lan-ws-token"))
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.path, "/api/lanShare/ws")
        XCTAssertEqual(url.port, 6688)
        XCTAssertEqual(url.host, "192.168.31.100")
        // token 仅在查询串里（必要协议例外），且没有 role=host。
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "token" })?.value, "lan-ws-token")
        XCTAssertNil(components.queryItems?.first(where: { $0.name == "role" }), "不得附带 role（默认 receiver）")
        // 绝不携带任何请求头凭据。
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-SPlayer-Token"))
    }

    func testCollaborationWebSocketPercentEncodesToken() throws {
        let request = try XCTUnwrap(APIRequestFactory.collaborationWebSocketRequest(baseURL: baseURL, wsToken: "a b&c=d/e"))
        let urlString = request.url?.absoluteString ?? ""
        XCTAssertFalse(urlString.contains("a b"))
        XCTAssertTrue(urlString.contains("token=a%20b%26c%3Dd%2Fe"), "查询串 token 必须百分号编码：\(urlString)")
    }

    func testCollaborationWebSocketUsesWSSForHTTPS() throws {
        let https = URL(string: "https://example.local/api/external")!
        let request = try XCTUnwrap(APIRequestFactory.collaborationWebSocketRequest(baseURL: https, wsToken: "t"))
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.path, "/api/lanShare/ws")
    }
}
