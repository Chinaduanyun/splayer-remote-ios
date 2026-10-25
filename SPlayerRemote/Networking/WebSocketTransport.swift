import Foundation

/// 单条 WebSocket 连接的连接状态。
/// 仅描述 socket 自身，**不代表** REST 是否可用：socket 断开时 REST 轮询继续工作。
enum RemoteSocketState: Equatable {
    case idle
    case connecting
    case open
    case closed
}

/// 可测试的 WebSocket 抽象。
///
/// 生产实现是 `URLSessionWebSocketTransport`；测试注入确定性 mock。
/// 回调不保证线程，调用方负责切回主线程（`RemoteViewModel` 已处理）。
protocol RemoteSocket: AnyObject {
    var state: RemoteSocketState { get }
    var onMessage: ((RemoteSocketMessage) -> Void)? { get set }
    var onStateChange: ((RemoteSocketState) -> Void)? { get set }
    func start()
    func stop()
}

typealias RemoteSocketFactory = (URL, String) -> RemoteSocket

extension APIRequestFactory {

    /// 构造 WebSocket 请求：`ws(s)://host:port/ws/external`。
    ///
    /// 与 REST 一致，Token **只放在请求头**（`Authorization` + `X-SPlayer-Token`），
    /// 绝不写入 URL / 查询参数，避免进入日志或被转发。
    static func webSocketRequest(baseURL: URL, token: String) -> URLRequest? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = (baseURL.scheme == "https") ? "wss" : "ws"
        components.path = "/ws/external"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
            request.setValue(trimmed, forHTTPHeaderField: "X-SPlayer-Token")
        }
        return request
    }
}

/// 生产 WebSocket 会话的 delegate。
///
/// - **拒绝一切 HTTP 重定向**（与 `RedirectDenyingDelegate` 的 REST 策略一致）：
///   携带鉴权头的握手请求绝不能被转发到其它主机；
/// - 上报握手完成（`.open`）与关闭（`.closed`），使 `RemoteViewModel` 能选择实时轮询节奏
///   并在成功握手后重置退避。
final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate {

    var onOpen: ((URLSessionWebSocketTask) -> Void)?
    var onClose: ((URLSessionWebSocketTask) -> Void)?
    /// 仅用于测试 / 可观测性：记录一次被拒绝的重定向。
    var onRedirectDenied: (() -> Void)?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol negotiatedProtocol: String?
    ) {
        onOpen?(webSocketTask)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose?(webSocketTask)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        onRedirectDenied?()
        // 返回 nil：URLSession 不跟随重定向，3xx 原样返回 / 握手失败。
        completionHandler(nil)
    }
}

/// 生产 WebSocket 实现：`URLSessionWebSocketTask` + 周期 ping。
///
/// - 只读：从不发送控制帧（命令仍走 HTTP，保证 ack 与不重放）；
/// - 握手完成由 `WebSocketSessionDelegate` 上报 `.open`；
/// - `stop()` 取消接收 / ping 任务与底层 task，并（自有会话时）失效会话，避免泄漏；
/// - 任何接收错误都收敛为 `.closed`，由 `RemoteViewModel` 决定是否回退 / 重连。
///
/// 并发策略：`task` / `isStopped` / 状态迁移 / 回调投递全部在同一个串行 `lifecycle` 队列上
/// 执行；`state` 与回调属性的读写由独立小锁保护。回调在锁外调用，且由于 open 回调与 stop
/// 在同一串行队列，stop 之后不会再有 `.open` 投递。
final class URLSessionWebSocketTransport: RemoteSocket {

    private let request: URLRequest
    /// 会话 delegate（测试可访问）。负责拒绝重定向并上报握手状态。
    let delegate: WebSocketSessionDelegate
    /// 底层会话（测试可访问）。
    let session: URLSession
    private let ownsSession: Bool
    private let pingIntervalNanoseconds: UInt64

    /// 保护 `currentState` 与回调属性的读写（临界区极短）。
    private let lock = NSLock()
    private var currentState: RemoteSocketState = .idle
    private var messageHandler: ((RemoteSocketMessage) -> Void)?
    private var stateHandler: ((RemoteSocketState) -> Void)?

    /// 串行化 task / stop / 握手 / 接收错误与回调投递。
    private let lifecycle = DispatchQueue(label: "com.example.splayerremote.websocket.lifecycle")
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var isStopped = false

    var onMessage: ((RemoteSocketMessage) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return messageHandler }
        set { lock.lock(); messageHandler = newValue; lock.unlock() }
    }

    var onStateChange: ((RemoteSocketState) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stateHandler }
        set { lock.lock(); stateHandler = newValue; lock.unlock() }
    }

    var state: RemoteSocketState {
        lock.lock(); defer { lock.unlock() }
        return currentState
    }

    init(
        request: URLRequest,
        session: URLSession? = nil,
        pingIntervalNanoseconds: UInt64 = 20_000_000_000
    ) {
        self.request = request
        self.pingIntervalNanoseconds = pingIntervalNanoseconds
        let delegate = WebSocketSessionDelegate()
        self.delegate = delegate
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 15
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            self.ownsSession = true
        }
        delegate.onOpen = { [weak self] task in self?.handleHandshakeOpen(task) }
        delegate.onClose = { [weak self] task in self?.handleHandshakeClose(task) }
    }

    /// 生产用 socket 工厂。`session` 仅用于测试注入。
    static func makeFactory(session: URLSession? = nil) -> RemoteSocketFactory {
        { baseURL, token in
            guard let request = APIRequestFactory.webSocketRequest(baseURL: baseURL, token: token) else {
                return DisabledRemoteSocket()
            }
            return URLSessionWebSocketTransport(request: request, session: session)
        }
    }

    func start() {
        lifecycle.sync {
            guard !isStopped, task == nil else { return }
            let newTask = session.webSocketTask(with: request)
            task = newTask
            if let handler = takeStateChange(.connecting) {
                handler(.connecting)
            }
            newTask.resume()
            startReceiveLoop(task: newTask)
            startPingLoop(task: newTask)
        }
    }

    func stop() {
        var taskToCancel: URLSessionWebSocketTask?
        var shouldInvalidate = false
        lifecycle.sync {
            guard !isStopped else { return }
            isStopped = true
            taskToCancel = task
            task = nil
            receiveTask?.cancel(); receiveTask = nil
            pingTask?.cancel(); pingTask = nil
            if let handler = takeStateChange(.closed) {
                handler(.closed)
            }
            shouldInvalidate = ownsSession
        }
        // 在串行队列之外取消 / 失效，避免与 delegate 回调互相阻塞。
        taskToCancel?.cancel(with: .goingAway, reason: nil)
        if shouldInvalidate {
            session.invalidateAndCancel()
        }
    }

    // MARK: - 测试支持

    /// 仅用于测试：直接安装底层 task，避免真实网络即可验证握手回调逻辑。
    func _installTask(_ installedTask: URLSessionWebSocketTask) {
        lifecycle.sync {
            guard !isStopped else { return }
            task = installedTask
        }
    }

    // MARK: - 内部（全部在 lifecycle 串行队列上）

    /// 更新状态并在有变化时返回需要投递的回调（回调在锁外调用）。
    private func takeStateChange(_ newState: RemoteSocketState) -> ((RemoteSocketState) -> Void)? {
        lock.lock()
        let changed = currentState != newState
        if changed { currentState = newState }
        let handler = changed ? stateHandler : nil
        lock.unlock()
        return handler
    }

    private func currentMessageHandler() -> ((RemoteSocketMessage) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return messageHandler
    }

    /// 握手完成：与 stop 在同一串行队列，因而 stop 之后不会投递 `.open`。
    private func handleHandshakeOpen(_ incoming: URLSessionWebSocketTask) {
        lifecycle.sync {
            guard !isStopped, incoming === task else { return }
            if let handler = takeStateChange(.open) {
                handler(.open)
            }
        }
    }

    /// 对端关闭 / 接收失败：同样串行化，并清除 task 以拒绝迟到的 open。
    private func handleHandshakeClose(_ incoming: URLSessionWebSocketTask) {
        lifecycle.sync {
            guard !isStopped, incoming === task else { return }
            task = nil
            if let handler = takeStateChange(.closed) {
                handler(.closed)
            }
        }
    }

    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard !Task.isCancelled else { return }
                    let text: String?
                    switch message {
                    case .string(let value):
                        text = value
                    case .data(let value):
                        text = String(data: value, encoding: .utf8)
                    @unknown default:
                        text = nil
                    }
                    if let text {
                        self?.enqueueMessage(text: text, from: task)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.enqueueReceiveFailure(from: task)
                    return
                }
            }
        }
    }

    private func enqueueMessage(text: String, from source: URLSessionWebSocketTask) {
        lifecycle.async { [weak self] in
            guard let self, !self.isStopped, source === self.task else { return }
            self.currentMessageHandler()?(RemoteSocketMessage.decode(from: text))
        }
    }

    private func enqueueReceiveFailure(from source: URLSessionWebSocketTask) {
        lifecycle.async { [weak self] in
            guard let self, !self.isStopped, source === self.task else { return }
            self.task = nil
            if let handler = self.takeStateChange(.closed) {
                handler(.closed)
            }
        }
    }

    private func startPingLoop(task: URLSessionWebSocketTask) {
        pingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = self.pingIntervalNanoseconds
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                task.sendPing { _ in }
            }
        }
    }
}

/// 占位实现：当无法构造合法 WS 请求时使用，立即以 `.closed` 通知调用方回退。
final class DisabledRemoteSocket: RemoteSocket {
    private(set) var state: RemoteSocketState = .idle
    var onMessage: ((RemoteSocketMessage) -> Void)?
    var onStateChange: ((RemoteSocketState) -> Void)?

    func start() {
        state = .closed
        onStateChange?(.closed)
    }

    func stop() {
        state = .closed
    }
}
