import Foundation

/// 协作控制通道抽象（`ws://host:port/api/lanShare/ws?token=<LAN_WSTOKEN>`）。
///
/// 与只读的外部实时通道（`/ws/external`）**相互独立**：它只在当前设备被主机授权时建立，
/// 用于上送 `playAt`。服务端没有可靠 ack，因此这里的“发送成功”只代表传输完成，
/// 绝不代表已播放；权威结果必须由之后的 `/api/external/now-playing` 校验。
///
/// 安全约定：
/// - 查询串里的 wsToken 只存在于本次连接的内存 URL 中，绝不持久化、绝不写入日志、
///   Activity 内容或错误文案；
/// - 明确不携带任何请求头凭据（外部 API token 仍只走请求头，二者不混用）；
/// - 与 REST / 外部 WS 一致，**拒绝一切 HTTP 重定向**；
/// - 只读地消费入站帧（用于保持连接健康），绝不把入站内容当作命令确认。
protocol CollaborationSocket: AnyObject {
    var state: RemoteSocketState { get }
    var onStateChange: ((RemoteSocketState) -> Void)? { get set }
    func start()
    func stop()
    /// 上送一个已编码的文本帧；返回是否已排入发送队列（**不代表对端已执行**）。
    @discardableResult
    func send(text: String) -> Bool
}

typealias CollaborationSocketFactory = (URL) -> CollaborationSocket

/// 生产协作通道：`URLSessionWebSocketTask`，只发送文本帧、入站帧安全忽略。
///
/// 并发策略与只读的外部传输一致：`task` / stop / 握手 / 接收失败全部在同一个串行
/// `lifecycle` 队列上串行化；`state` 与回调由独立小锁保护；回调在锁外投递。
final class URLSessionCollaborationTransport: CollaborationSocket {

    /// 会话 delegate（测试可访问）。负责拒绝重定向并上报握手状态。
    let delegate: WebSocketSessionDelegate
    /// 底层会话（测试可访问）。
    let session: URLSession

    private let request: URLRequest
    private let ownsSession: Bool

    private let lock = NSLock()
    private var currentState: RemoteSocketState = .idle
    private var stateHandler: ((RemoteSocketState) -> Void)?

    private let lifecycle = DispatchQueue(label: "com.example.splayerremote.collaboration.lifecycle")
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var isStopped = false
    private var isOpen = false

    var onStateChange: ((RemoteSocketState) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stateHandler }
        set { lock.lock(); stateHandler = newValue; lock.unlock() }
    }

    var state: RemoteSocketState {
        lock.lock(); defer { lock.unlock() }
        return currentState
    }

    init(url: URL, session: URLSession? = nil) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 不设置 Authorization / X-SPlayer-Token：查询串 token 是经过批准的协议例外，
        // 绝不额外转发外部 API 凭据。
        self.request = request
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
        delegate.onOpen = { [weak self] incoming in self?.handleOpen(incoming) }
        delegate.onClose = { [weak self] incoming in self?.handleClose(incoming) }
    }

    /// 生产用协作通道工厂。`session` 仅用于测试注入。
    static func makeFactory(session: URLSession? = nil) -> CollaborationSocketFactory {
        { url in URLSessionCollaborationTransport(url: url, session: session) }
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
        }
    }

    func stop() {
        var taskToCancel: URLSessionWebSocketTask?
        var shouldInvalidate = false
        lifecycle.sync {
            guard !isStopped else { return }
            isStopped = true
            isOpen = false
            taskToCancel = task
            task = nil
            receiveTask?.cancel(); receiveTask = nil
            if let handler = takeStateChange(.closed) {
                handler(.closed)
            }
            shouldInvalidate = ownsSession
        }
        taskToCancel?.cancel(with: .goingAway, reason: nil)
        if shouldInvalidate {
            session.invalidateAndCancel()
        }
    }

    @discardableResult
    func send(text: String) -> Bool {
        var accepted = false
        lifecycle.sync {
            guard !isStopped, isOpen, let task else { return }
            accepted = true
            task.send(.string(text)) { _ in }
        }
        return accepted
    }

    // MARK: - 内部（全部在 lifecycle 串行队列上）

    private func takeStateChange(_ newState: RemoteSocketState) -> ((RemoteSocketState) -> Void)? {
        lock.lock()
        let changed = currentState != newState
        if changed { currentState = newState }
        let handler = changed ? stateHandler : nil
        lock.unlock()
        return handler
    }

    private func handleOpen(_ incoming: URLSessionWebSocketTask) {
        lifecycle.sync {
            guard !isStopped, incoming === task else { return }
            isOpen = true
            if let handler = takeStateChange(.open) {
                handler(.open)
            }
        }
    }

    private func handleClose(_ incoming: URLSessionWebSocketTask) {
        lifecycle.sync {
            guard !isStopped, incoming === task else { return }
            isOpen = false
            task = nil
            if let handler = takeStateChange(.closed) {
                handler(.closed)
            }
        }
    }

    /// 只读地排空入站帧：既保持连接健康，又避免把入站内容误当命令确认。
    private func startReceiveLoop(task: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    _ = try await task.receive()
                    guard !Task.isCancelled else { return }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.enqueueReceiveFailure(from: task)
                    return
                }
            }
        }
    }

    private func enqueueReceiveFailure(from source: URLSessionWebSocketTask) {
        lifecycle.async { [weak self] in
            guard let self, !self.isStopped, source === self.task else { return }
            self.isOpen = false
            self.task = nil
            if let handler = self.takeStateChange(.closed) {
                handler(.closed)
            }
        }
    }
}
