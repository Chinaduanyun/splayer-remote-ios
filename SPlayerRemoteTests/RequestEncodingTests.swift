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
}
