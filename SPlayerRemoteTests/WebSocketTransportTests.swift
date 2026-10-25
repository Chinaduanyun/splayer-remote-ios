import XCTest
@testable import SPlayerRemote

/// 生产 WebSocket 传输的 delegate 策略（拒绝重定向）与握手状态上报。
/// 全部为离线确定性测试：不发起任何真实网络请求。
final class WebSocketTransportTests: XCTestCase {

    private let baseURL = URL(string: "http://192.168.31.100:6688/api/external")!

    private func makeTask() -> (URLSession, URLSessionWebSocketTask) {
        let session = TestSession.make()
        let task = session.webSocketTask(with: URL(string: "ws://192.168.31.100:6688/ws/external")!)
        return (session, task)
    }

    // MARK: - R1：拒绝重定向

    func testDelegateRejectsEveryRedirect() {
        let delegate = WebSocketSessionDelegate()
        var deniedCount = 0
        delegate.onRedirectDenied = { deniedCount += 1 }

        let (session, task) = makeTask()
        let response = HTTPURLResponse(
            url: baseURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "http://evil.example/steal"]
        )!
        let redirected = URLRequest(url: URL(string: "http://evil.example/steal")!)

        var returned: URLRequest?
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirected
        ) { request in
            returned = request
        }

        XCTAssertNil(returned, "鉴权握手请求不得被转发")
        XCTAssertEqual(deniedCount, 1)
    }

    func testTransportSessionUsesRedirectDenyingDelegate() throws {
        let request = try XCTUnwrap(APIRequestFactory.webSocketRequest(baseURL: baseURL, token: "secret-token"))
        let transport = URLSessionWebSocketTransport(request: request)
        defer { transport.stop() }

        XCTAssertTrue(transport.session.delegate === transport.delegate)
        XCTAssertTrue(transport.session.delegate is URLSessionWebSocketDelegate)
    }

    // MARK: - R2：握手状态上报

    func testDelegateForwardsHandshakeOpenAndClose() {
        let delegate = WebSocketSessionDelegate()
        let (_, task) = makeTask()
        var opened = false
        var closed = false
        delegate.onOpen = { _ in opened = true }
        delegate.onClose = { _ in closed = true }

        delegate.urlSession(URLSession.shared, webSocketTask: task, didOpenWithProtocol: nil)
        XCTAssertTrue(opened)

        delegate.urlSession(URLSession.shared, webSocketTask: task, didCloseWith: .goingAway, reason: nil)
        XCTAssertTrue(closed)
    }

    func testTransportReportsOpenThenClosedFromHandshakeCallbacks() throws {
        let request = try XCTUnwrap(APIRequestFactory.webSocketRequest(baseURL: baseURL, token: "t"))
        let transport = URLSessionWebSocketTransport(request: request, session: TestSession.make())
        let task = transport.session.webSocketTask(with: request.url!)

        transport._installTask(task)
        transport.delegate.onOpen?(task)
        XCTAssertEqual(transport.state, .open)

        transport.delegate.onClose?(task)
        XCTAssertEqual(transport.state, .closed)
    }

    func testLateHandshakeOpenAfterStopCannotReopen() throws {
        let request = try XCTUnwrap(APIRequestFactory.webSocketRequest(baseURL: baseURL, token: "t"))
        let transport = URLSessionWebSocketTransport(request: request, session: TestSession.make())
        let task = transport.session.webSocketTask(with: request.url!)

        transport._installTask(task)
        transport.delegate.onOpen?(task)
        XCTAssertEqual(transport.state, .open)

        transport.stop()
        XCTAssertEqual(transport.state, .closed)

        // stop 之后到达的握手回调必须被 task 身份校验丢弃。
        transport.delegate.onOpen?(task)
        XCTAssertEqual(transport.state, .closed, "stop 后不得重新打开连接")
    }

    func testStartAfterStopDoesNotReconnect() throws {
        let request = try XCTUnwrap(APIRequestFactory.webSocketRequest(baseURL: baseURL, token: "t"))
        let transport = URLSessionWebSocketTransport(request: request, session: TestSession.make())
        transport.stop()
        transport.start()
        XCTAssertEqual(transport.state, .closed)
    }

    /// 握手 open 与 stop 竞争：无论谁先执行，最终必须是 closed，且不会在 closed 后再投递 open。
    func testConcurrentOpenAndStopAlwaysEndsClosed() throws {
        for _ in 0..<20 {
            let request = try XCTUnwrap(APIRequestFactory.webSocketRequest(baseURL: baseURL, token: "t"))
            let transport = URLSessionWebSocketTransport(request: request, session: TestSession.make())
            let task = transport.session.webSocketTask(with: request.url!)
            transport._installTask(task)

            let historyLock = NSLock()
            var history: [RemoteSocketState] = []
            transport.onStateChange = { state in
                historyLock.lock(); history.append(state); historyLock.unlock()
            }

            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                transport.delegate.onOpen?(task)
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                transport.stop()
                group.leave()
            }
            group.wait()

            XCTAssertEqual(transport.state, .closed)
            historyLock.lock()
            let seen = history
            historyLock.unlock()
            XCTAssertNotEqual(seen.last, .open, "closed 之后不得再投递 open：\(seen)")
        }
    }

    // MARK: - F6：协作传输关闭 / 迟到回调

    func testCollaborationTransportIgnoresLateOpenAfterClose() throws {
        let url = try XCTUnwrap(URL(string: "ws://192.168.31.100:6688/api/lanShare/ws?token=synthetic"))
        let transport = URLSessionCollaborationTransport(url: url, session: TestSession.make())
        let task = transport.session.webSocketTask(with: url)
        transport._installTask(task)

        transport.delegate.onOpen?(task)
        XCTAssertEqual(transport.state, .open)

        // 对端非预期关闭：必须收敛为 closed。
        transport.delegate.onClose?(task)
        XCTAssertEqual(transport.state, .closed)

        // 关闭后迟到的 open 不得重建通道。
        transport.delegate.onOpen?(task)
        XCTAssertEqual(transport.state, .closed, "关闭后的迟到 open 不得重建")

        // stop 幂等。
        transport.stop()
        XCTAssertEqual(transport.state, .closed)
    }

    func testCollaborationTransportRejectsRedirect() throws {
        let url = try XCTUnwrap(URL(string: "ws://192.168.31.100:6688/api/lanShare/ws?token=synthetic"))
        let transport = URLSessionCollaborationTransport(url: url, session: TestSession.make())
        var denied = 0
        transport.delegate.onRedirectDenied = { denied += 1 }
        let (session, task) = makeTask()
        let response = HTTPURLResponse(url: baseURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
        transport.delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "http://evil.example/steal")!)
        ) { request in
            XCTAssertNil(request)
        }
        XCTAssertEqual(denied, 1)
    }
}
