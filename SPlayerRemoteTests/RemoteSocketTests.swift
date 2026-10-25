import XCTest
@testable import SPlayerRemote

/// WebSocket 事件解码与请求契约（无网络、确定性）。
final class RemoteSocketTests: XCTestCase {

    private let baseURL = URL(string: "http://192.168.31.100:6688/api/external")!

    // MARK: - 事件解码

    func testDecodesHelloWithClients() {
        let message = RemoteSocketMessage.decode(from: #"{"kind":"hello","clients":1}"#)
        XCTAssertEqual(message, .hello(clients: 1))
    }

    func testDecodesHelloWithoutClients() {
        let message = RemoteSocketMessage.decode(from: #"{"kind":"hello"}"#)
        XCTAssertEqual(message, .hello(clients: nil))
    }

    func testDecodesStateChangedPayloadAndIgnoresSrc() {
        let json = #"""
        {"kind":"event","type":"stateChanged","data":{"src":"http://secret.example/media?id=abc","songId":7,"paused":false,"ready":true,"playing":true,"buffering":false,"durationMs":240000,"positionMs":12000,"volume":0.5,"playbackRate":1.25,"errorCode":0}}
        """#
        guard case .stateChanged(let payload) = RemoteSocketMessage.decode(from: json) else {
            return XCTFail("应为 stateChanged")
        }
        XCTAssertEqual(payload.songId, 7)
        XCTAssertEqual(payload.playing, true)
        XCTAssertEqual(payload.ready, true)
        XCTAssertEqual(payload.durationMs, 240000)
        XCTAssertEqual(payload.positionMs, 12000)
        XCTAssertEqual(payload.volume, 0.5)
        XCTAssertEqual(payload.playbackRate, 1.25)
        XCTAssertEqual(payload.errorCode, 0)
    }

    /// 只包含 src 的负载不得产生任何可用字段（src 被刻意忽略）。
    func testStateChangedWithOnlySrcYieldsNoFields() {
        let json = #"{"kind":"event","type":"stateChanged","data":{"src":"http://secret.example/x"}}"#
        guard case .stateChanged(let payload) = RemoteSocketMessage.decode(from: json) else {
            return XCTFail("应为 stateChanged")
        }
        XCTAssertNil(payload.songId)
        XCTAssertNil(payload.playing)
        XCTAssertNil(payload.durationMs)
        XCTAssertNil(payload.positionMs)
        XCTAssertNil(payload.volume)
    }

    func testDecodesPartialStateChanged() {
        let json = #"{"kind":"event","type":"stateChanged","data":{"positionMs":5000}}"#
        guard case .stateChanged(let payload) = RemoteSocketMessage.decode(from: json) else {
            return XCTFail("应为 stateChanged")
        }
        XCTAssertEqual(payload.positionMs, 5000)
        XCTAssertNil(payload.playing)
        XCTAssertNil(payload.volume)
    }

    func testDecodesEndedWithoutData() {
        let json = #"{"kind":"event","type":"ended"}"#
        XCTAssertEqual(RemoteSocketMessage.decode(from: json), .ended)
    }

    func testDecodesAckAndError() {
        XCTAssertEqual(RemoteSocketMessage.decode(from: #"{"kind":"ack","op":"play"}"#), .ack(op: "play"))
        XCTAssertEqual(
            RemoteSocketMessage.decode(from: #"{"kind":"error","op":"seek","error":"bad"}"#),
            .error(op: "seek", message: "bad")
        )
    }

    func testUnknownKindEventTypeAndInvalidJSONAreIgnored() {
        XCTAssertEqual(RemoteSocketMessage.decode(from: #"{"kind":"mystery"}"#), .unknown)
        XCTAssertEqual(RemoteSocketMessage.decode(from: #"{"kind":"event","type":"fancy"}"#), .unknown)
        XCTAssertEqual(RemoteSocketMessage.decode(from: #"{"kind":"event","type":"stateChanged"}"#), .unknown)
        XCTAssertEqual(RemoteSocketMessage.decode(from: "not json"), .unknown)
        XCTAssertEqual(RemoteSocketMessage.decode(from: "[1,2,3]"), .unknown)
        XCTAssertEqual(RemoteSocketMessage.decode(from: ""), .unknown)
    }

    // MARK: - 请求契约

    func testWebSocketURLAndHeaders() throws {
        let request = try XCTUnwrap(APIRequestFactory.webSocketRequest(baseURL: baseURL, token: "secret-token"))
        XCTAssertEqual(request.url?.absoluteString, "ws://192.168.31.100:6688/ws/external")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SPlayer-Token"), "secret-token")
    }

    func testWebSocketTokenNeverAppearsInURLOdds() throws {
        let request = try XCTUnwrap(APIRequestFactory.webSocketRequest(baseURL: baseURL, token: "secret-token"))
        let urlString = request.url?.absoluteString ?? ""
        XCTAssertFalse(urlString.contains("secret-token"))
        XCTAssertFalse(urlString.contains("token="))
        XCTAssertFalse(urlString.contains("?"))
    }

    func testWebSocketUsesWSSForHTTPS() throws {
        let https = URL(string: "https://example.local/api/external")!
        let request = try XCTUnwrap(APIRequestFactory.webSocketRequest(baseURL: https, token: "t"))
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.path, "/ws/external")
    }

    func testWebSocketNoAuthHeadersWhenTokenBlank() throws {
        let request = try XCTUnwrap(APIRequestFactory.webSocketRequest(baseURL: baseURL, token: "   "))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-SPlayer-Token"))
    }
}
