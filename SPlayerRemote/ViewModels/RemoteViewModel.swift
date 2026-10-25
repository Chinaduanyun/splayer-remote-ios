import Foundation
import Combine

/// 连接与播放状态的中枢。所有 UI 状态变更都在主线程进行。
///
/// 设计要点：
/// - 只有 info + status 都成功获取才认为连接成功；
/// - 场景激活且已连接时才轮询；只有一条轮询任务；
/// - 每次连接都会递增 `generation`，并捕获一份**不可变** `ConnectionConfiguration`；
///   REST 与所有 WebSocket 重试都复用同一份，过期响应会被丢弃；
/// - 后台返回的轮询/连接/命令/WS 结果一律丢弃，不能在后台启用命令；
/// - 命令请求互斥（`isCommandInFlight`）且可保留取消，世代不符的旧完成不得改动状态；
/// - 轮询遇到非致命错误时保持重试但标记 `isStale`，在成功刷新前禁用控制；
/// - WebSocket 是**可选、只读**的实时通道：断开时 REST 轮询继续工作，
///   socket 不可用绝不等于 REST 断开。所有命令仍走 HTTP。
@MainActor
final class RemoteViewModel: ObservableObject {

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var isConnected: Bool { self == .connected }
    }

    /// WebSocket 传输状态（与 REST 连接状态相互独立）。
    enum TransportState: Equatable {
        case disabled
        case connecting
        case live
        case fallback

        var displayName: String {
            switch self {
            case .disabled: return "已停用"
            case .connecting: return "连接中"
            case .live: return "实时"
            case .fallback: return "轮询回退"
            }
        }
    }

    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var info: InfoResponse?
    @Published private(set) var status: StatusResponse?
    @Published private(set) var nowPlaying: NowPlayingResponse?
    @Published private(set) var lastError: String?
    @Published private(set) var isCommandInFlight = false
    /// 播放数据可能过期的状态；成功刷新（REST 或已验证的 WS 状态事件）前禁用控制。
    @Published private(set) var isStale = false
    /// REST 特有的降级标记：只由 REST 请求结果驱动，绝不被任何 socket 流量清除。
    @Published private(set) var isRestDegraded = false

    // MARK: - 诊断 / 实时状态（只读）

    @Published private(set) var transport: TransportState = .disabled
    @Published private(set) var wsClientCount: Int?
    @Published private(set) var lastSuccessfulUpdate: Date?
    @Published private(set) var lastSuccessfulRestUpdate: Date?
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var isReady: Bool?
    @Published private(set) var remoteErrorCode: Int?

    /// 滑杆草稿；为 nil 时表示跟随远端轮询值。
    @Published var volumeDraft: Double?
    @Published var seekDraft: Double?
    @Published private(set) var isAdjustingVolume = false
    @Published private(set) var isAdjustingSeek = false
    /// 本地记忆的「取消静音」音量；**不是**手机系统音量。
    @Published private(set) var rememberedVolume: Double = 0.5

    let settings: SettingsStore
    private let clientFactory: (URL, String) -> RemoteAPI
    private let socketFactory: RemoteSocketFactory?
    private var client: RemoteAPI?
    private var socket: RemoteSocket?
    private var pollTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var generation = 0
    private var socketGeneration = 0
    private var reconnectAttempt = 0
    private var isSceneActive = true
    private var suppressAutoConnect = false

    /// 本次连接的不可变配置：REST + WS 重试共用，绝不读取编辑中的设置。
    private var activeConfiguration: ConnectionConfiguration?

    private let pollIntervalNanoseconds: UInt64
    private let wsPollIntervalNanoseconds: UInt64
    private let reconnectDelays: [UInt64]
    private let monotonicNow: () -> TimeInterval
    private let dateProvider: () -> Date

    /// 用于丢弃「早于最新 WS 事件」的轮询结果，避免无序快照相互覆盖。
    private var wsArrivalCount = 0

    /// 权威曲目标识（`nowPlaying` 缺失时仍可跟踪）。
    private var trackedSongId: Int?

    /// 平滑进度的单调锚点：以权威快照为基准，用本地单调时钟外推。
    private struct ProgressAnchor {
        var positionMs: Double
        var uptime: TimeInterval
        var durationMs: Double
        var isAdvancing: Bool
        var rate: Double
    }
    private var progressAnchor: ProgressAnchor?

    /// 拖动手势身份：曲目 + 连接世代。曲目/连接改变时手势失效，释放不再上报。
    private struct SeekDragIdentity: Equatable {
        let songId: Int?
        let generation: Int
    }
    private var seekDragIdentity: SeekDragIdentity?
    private var seekDraftInvalidated = false

    nonisolated init(
        settings: SettingsStore,
        clientFactory: @escaping (URL, String) -> RemoteAPI = { url, token in
            RemoteAPIClient(baseURL: url, token: token)
        },
        pollIntervalNanoseconds: UInt64 = 2_000_000_000,
        socketFactory: RemoteSocketFactory? = nil,
        wsPollIntervalNanoseconds: UInt64 = 5_000_000_000,
        reconnectDelays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000],
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        dateProvider: @escaping () -> Date = { Date() }
    ) {
        self.settings = settings
        self.clientFactory = clientFactory
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.socketFactory = socketFactory
        self.wsPollIntervalNanoseconds = wsPollIntervalNanoseconds
        self.reconnectDelays = reconnectDelays.isEmpty ? [1_000_000_000] : reconnectDelays
        self.monotonicNow = monotonicNow
        self.dateProvider = dateProvider
    }

    // MARK: - 派生状态

    /// 只有「场景激活 + 已连接 + 非过期 + 无命令在途」时才允许控制，
    /// 后台或数据过期一律禁用不安全控件。
    var canControl: Bool {
        isSceneActive && connection.isConnected && !isStale && !isCommandInFlight
    }

    /// 仅在已知有效时长时允许跳转。
    var canSeek: Bool { canControl && currentDurationMs > 0 }

    /// 当前用于 UI 显示的播放状态。
    var playbackState: PlaybackState {
        if let nowPlaying, nowPlaying.playing { return .playing }
        if let nowPlaying, nowPlaying.buffering { return .buffering }
        return status?.state ?? .unknown
    }

    /// REST 是否可用：必须由成功的 REST 请求证明，**绝不被 socket 流量影响**。
    var restAvailable: Bool { connection.isConnected && !isRestDegraded }

    var isBuffering: Bool {
        if let nowPlaying, nowPlaying.buffering { return true }
        return status?.state == .buffering
    }

    var isMuted: Bool { currentVolume <= 0.001 }

    /// 权威曲目标识（优先 `nowPlaying`，否则用 WS 跟踪值）。
    var songId: Int? { nowPlaying?.songId ?? trackedSongId }

    private var rawPositionMs: Int { nowPlaying?.position ?? status?.position ?? 0 }
    private var rawDurationMs: Int { nowPlaying?.duration ?? status?.duration ?? 0 }

    var currentDurationMs: Int { rawDurationMs }

    var currentVolume: Double { nowPlaying?.volume ?? status?.volume ?? 1 }

    /// 平滑外推的播放位置（毫秒）。
    /// 播放中且前台、数据新鲜、未缓冲时才前进；否则冻结在「当前显示位置」，绝不回退。
    var currentPositionMs: Int {
        guard let anchor = progressAnchor else { return rawPositionMs }
        let base = clampToDuration(anchor.positionMs, duration: anchor.durationMs)
        guard anchor.isAdvancing, isSceneActive, !isStale else { return safeInt(base) }
        let projected = projectedPosition(from: anchor, at: monotonicNow())
        return safeInt(max(base, clampToDuration(projected, duration: anchor.durationMs)))
    }

    // MARK: - 连接生命周期

    func connect() async {
        suppressAutoConnect = false
        disconnect(resetState: false)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performConnection()
        }
        connectionTask = task
        await task.value
    }

    /// 自动连接入口：仅在用户显式开启、已保存可用主机 + Token、且未主动断开时执行。
    /// 只使用**已提交**的配置（`hasSavedConnection`），不会泄漏编辑中的草稿。
    func connectIfConfigured() async {
        guard settings.autoConnect,
              !suppressAutoConnect,
              settings.hasSavedConnection else { return }
        guard connection != .connected, connection != .connecting else { return }
        await connect()
    }

    private func performConnection() async {
        guard isSceneActive, !Task.isCancelled else { return }

        let configuration: ConnectionConfiguration
        do {
            configuration = try settings.makeConfiguration()
        } catch {
            connection = .failed(message(for: error))
            lastError = message(for: error)
            return
        }

        let newClient = clientFactory(configuration.baseURL, configuration.token)

        generation += 1
        let gen = generation
        activeConfiguration = configuration
        client = newClient
        connection = .connecting
        lastError = nil
        isStale = false
        isRestDegraded = false
        status = nil
        nowPlaying = nil
        trackedSongId = nil
        progressAnchor = nil

        do {
            // info 与 status 都必须成功，才认为连接“好”。
            let fetchedInfo = try await newClient.fetchInfo()
            guard gen == generation, isSceneActive, !Task.isCancelled else { return }
            let fetchedStatus = try await newClient.fetchStatus()

            // 连接被新的 connect/disconnect 取代：静默退出。
            guard gen == generation, !Task.isCancelled else { return }
            // 连接在后台完成：不启用命令，回到断开态，前台恢复时需重连。
            guard isSceneActive else {
                finishConnectAfterBackground()
                return
            }
            info = fetchedInfo
            status = fetchedStatus

            let fetchedNow = try? await newClient.fetchNowPlaying()
            guard gen == generation, !Task.isCancelled else { return }
            guard isSceneActive else {
                finishConnectAfterBackground()
                return
            }
            nowPlaying = fetchedNow
            trackedSongId = fetchedNow?.songId

            connection = .connected
            isStale = false
            isRestDegraded = false
            lastError = nil
            let now = dateProvider()
            lastSuccessfulUpdate = now
            lastSuccessfulRestUpdate = now
            updateProgressAnchor(authoritativePosition: rawPositionMs)
            startPolling()
            startSocketIfNeeded()
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            client = nil
            connection = .failed(message(for: error))
            lastError = message(for: error)
        }
    }

    /// 连接在后台期间完成：不保留客户端、不启用命令。
    private func finishConnectAfterBackground() {
        client = nil
        activeConfiguration = nil
        connection = .disconnected
        isStale = false
        lastError = nil
    }

    func disconnect(resetState: Bool = true) {
        generation += 1
        connectionTask?.cancel()
        connectionTask = nil
        stopPolling()
        teardownSocket()
        invalidateCommand()
        client = nil
        activeConfiguration = nil
        reconnectAttempt = 0
        transport = .disabled
        if resetState {
            connection = .disconnected
            info = nil
            status = nil
            nowPlaying = nil
            volumeDraft = nil
            seekDraft = nil
            lastError = nil
            isStale = false
            isRestDegraded = false
            isAdjustingVolume = false
            isAdjustingSeek = false
            seekDragIdentity = nil
            seekDraftInvalidated = false
            wsClientCount = nil
            lastSuccessfulUpdate = nil
            lastSuccessfulRestUpdate = nil
            playbackRate = 1
            isReady = nil
            remoteErrorCode = nil
            progressAnchor = nil
            trackedSongId = nil
        }
    }

    /// 用户主动断开：同时抑制后续前台自动重连，直到再次手动连接。
    func disconnectByUser() {
        suppressAutoConnect = true
        disconnect()
    }

    /// 由场景阶段驱动：进入后台时取消所有网络工作；回到前台且已连接时恢复轮询与 socket。
    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        if active {
            if connection.isConnected {
                updateProgressAnchor()
                startPolling()
                startSocketIfNeeded()
            }
        } else {
            generation += 1
            connectionTask?.cancel()
            connectionTask = nil
            stopPolling()
            teardownSocket()
            invalidateCommand()
            isStale = true
            volumeDraft = nil
            if isAdjustingSeek { seekDraftInvalidated = true }
            isAdjustingVolume = false
            isAdjustingSeek = false
            seekDraft = nil
            updateProgressAnchor()
            transport = (activeConfiguration?.useWebSocket == true) ? .fallback : .disabled
            if connection == .connecting {
                client = nil
                connection = .disconnected
            }
        }
    }

    // MARK: - WebSocket 实时通道

    private func startSocketIfNeeded() {
        guard isSceneActive, connection.isConnected else { return }
        guard let configuration = activeConfiguration else { return }
        guard configuration.useWebSocket, let socketFactory else {
            transport = configuration.useWebSocket ? .fallback : .disabled
            return
        }
        guard socket == nil else { return }

        socketGeneration += 1
        let gen = generation
        let socketGen = socketGeneration
        // 复用连接时捕获的配置，绝不读取可能已被编辑的 settings。
        let newSocket = socketFactory(configuration.baseURL, configuration.token)
        newSocket.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handleSocketMessage(message, generation: gen, socketGeneration: socketGen)
            }
        }
        newSocket.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleSocketState(state, generation: gen, socketGeneration: socketGen)
            }
        }
        socket = newSocket
        transport = .connecting
        newSocket.start()
    }

    private func teardownSocket() {
        // 递增 socket 世代：任何仍在途的旧回调都会被丢弃。
        socketGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.onMessage = nil
        socket?.onStateChange = nil
        socket?.stop()
        socket = nil
    }

    private func handleSocketState(
        _ state: RemoteSocketState,
        generation gen: Int,
        socketGeneration socketGen: Int
    ) {
        guard gen == generation, socketGen == socketGeneration, isSceneActive else { return }
        switch state {
        case .open:
            reconnectAttempt = 0
            transport = .live
        case .closed:
            teardownSocket()
            transport = .fallback
            scheduleReconnect(generation: gen)
        case .idle, .connecting:
            break
        }
    }

    private func handleSocketMessage(
        _ message: RemoteSocketMessage,
        generation gen: Int,
        socketGeneration socketGen: Int
    ) {
        guard gen == generation, socketGen == socketGeneration, isSceneActive else { return }
        switch message {
        case .hello(let clients):
            // 仅仅更新客户端数；不视为状态快照，不清除过期、不恢复 REST 可用性。
            if let clients { wsClientCount = clients }
        case .stateChanged(let payload):
            // 只有携带可验证状态的事件才能清除「过期」；空/仅 src/仅音量不在此列。
            if payload.isStatusBearing { isStale = false }
            applyStateChanged(payload)
            if payload.isStatusBearing {
                wsArrivalCount += 1
                lastSuccessfulUpdate = dateProvider()
                lastError = nil
            }
        case .ended:
            // 终态：冻结进度并参与快照排序；不得恢复过期/REST 健康。
            applyEnded()
            wsArrivalCount += 1
        case .ack, .error, .unknown:
            // 只读通道：确认 / 错误 / 未知事件一律安全忽略。
            break
        }
    }

    /// 把 WS 事件合并进权威快照（缺失字段不覆盖），并重建进度锚点。
    private func applyStateChanged(_ payload: StateChangedPayload) {
        if let songId = payload.songId {
            let previousSongId = trackedSongId
            trackedSongId = songId
            nowPlaying?.songId = songId
            if songId != previousSongId {
                invalidateSeekDragIfNeeded(newSongId: songId)
            }
        }

        if let volume = payload.volume, volume.isFinite {
            let clamped = min(max(volume, 0), 1)
            nowPlaying?.volume = clamped
            status?.volume = clamped
        }
        if let duration = payload.durationMs, duration >= 0 {
            nowPlaying?.duration = duration
            status?.duration = duration
        }
        if let position = payload.positionMs, position >= 0 {
            nowPlaying?.position = position
            status?.position = position
        }
        if let playing = payload.playing { nowPlaying?.playing = playing }
        if let buffering = payload.buffering { nowPlaying?.buffering = buffering }
        if let paused = payload.paused { nowPlaying?.paused = paused }

        // 仅当事件携带播放/缓冲信息时才改写权威 `status.state`，避免用旧值自证。
        if let playing = payload.playing {
            if playing {
                status?.state = .playing
            } else if payload.buffering == true || nowPlaying?.buffering == true {
                status?.state = .buffering
            } else {
                status?.state = .paused
            }
        } else if let buffering = payload.buffering {
            if buffering {
                status?.state = .buffering
            } else if nowPlaying?.playing == true {
                status?.state = .playing
            } else if nowPlaying?.paused == true {
                status?.state = .paused
            }
        }

        if let rate = payload.playbackRate, rate.isFinite, rate > 0 {
            playbackRate = rate
        }
        if let ready = payload.ready { isReady = ready }
        if let errorCode = payload.errorCode { remoteErrorCode = errorCode }

        let authoritativePosition: Int? = {
            if let position = payload.positionMs, position >= 0 { return position }
            return nil
        }()
        updateProgressAnchor(authoritativePosition: authoritativePosition)
    }

    /// `ended` 没有 data：不制造位置，只把状态收敛为非播放并冻结在当前位置。
    private func applyEnded() {
        nowPlaying?.playing = false
        nowPlaying?.buffering = false
        nowPlaying?.paused = true
        status?.state = .paused
        status?.isFinished = true
        updateProgressAnchor()
    }

    private func scheduleReconnect(generation gen: Int) {
        guard isSceneActive, connection.isConnected,
              let configuration = activeConfiguration, configuration.useWebSocket,
              socketFactory != nil else { return }
        guard reconnectTask == nil else { return }
        let index = min(reconnectAttempt, reconnectDelays.count - 1)
        let delay = reconnectDelays[index]
        reconnectAttempt += 1
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard gen == self.generation, self.isSceneActive, self.connection.isConnected else { return }
            self.startSocketIfNeeded()
        }
    }

    // MARK: - 轮询

    private var effectivePollInterval: UInt64 {
        transport == .live ? wsPollIntervalNanoseconds : pollIntervalNanoseconds
    }

    private func startPolling() {
        stopPolling()
        guard isSceneActive, client != nil else { return }
        let gen = generation
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.effectivePollInterval
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, self.isSceneActive else { return }
                await self.pollOnce(expectedGeneration: gen)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 手动刷新一次（不启动轮询循环），用于「重试」与测试。
    func refreshNow() async {
        await pollOnce(expectedGeneration: generation)
    }

    private func pollOnce(expectedGeneration gen: Int) async {
        guard gen == generation, let client else { return }
        let wsArrivalAtStart = wsArrivalCount
        do {
            async let statusTask = client.fetchStatus()
            async let nowTask = client.fetchNowPlaying()
            let (freshStatus, freshNow) = try await (statusTask, nowTask)

            // 丢弃过期或后台返回的响应，避免覆盖新连接 / 后台状态。
            guard gen == generation, isSceneActive, !Task.isCancelled else { return }
            // 已有更新的 WS 快照（含 ended）到达：丢弃这次较早发起的轮询。
            guard wsArrivalCount == wsArrivalAtStart else { return }

            status = freshStatus
            nowPlaying = freshNow
            let previousSongId = trackedSongId
            trackedSongId = freshNow.songId
            if freshNow.songId != previousSongId {
                invalidateSeekDragIfNeeded(newSongId: freshNow.songId)
            }
            if !isAdjustingVolume { volumeDraft = nil }
            if !isAdjustingSeek { seekDraft = nil }
            if !connection.isConnected { connection = .connected }
            isStale = false
            isRestDegraded = false
            lastError = nil
            let now = dateProvider()
            lastSuccessfulUpdate = now
            lastSuccessfulRestUpdate = now
            updateProgressAnchor(authoritativePosition: rawPositionMs)
        } catch {
            guard gen == generation, isSceneActive, !Task.isCancelled else { return }
            if let apiError = error as? RemoteAPIError, case .cancelled = apiError { return }
            if isFatal(error) {
                // 401/403：连接已失效，停止轮询与 socket 并进入失败态。
                stopPolling()
                teardownSocket()
                invalidateCommand()
                isStale = true
                isRestDegraded = true
                connection = .failed(message(for: error))
                lastError = message(for: error)
            } else {
                // 非致命（网络等）：保持轮询自动重试，但标记数据过期并冻结进度（不回退）。
                isStale = true
                isRestDegraded = true
                lastError = message(for: error)
                updateProgressAnchor()
            }
        }
    }

    private func isFatal(_ error: Error) -> Bool {
        guard let apiError = error as? RemoteAPIError else { return false }
        switch apiError {
        case .unauthorized, .forbidden, .invalidConfiguration:
            return true
        default:
            return false
        }
    }

    // MARK: - 控制命令

    func send(_ command: RemoteCommand) {
        runControl { client in
            try await client.send(command: command)
        }
    }

    /// 统一的控制请求执行器：互斥、可取消、带世代保护、绝不自动重试。
    private func runControl(_ operation: @escaping (RemoteAPI) async throws -> Void) {
        guard canControl, let client else { return }
        let gen = generation
        commandTask?.cancel()
        isCommandInFlight = true
        commandTask = Task { @MainActor [weak self] in
            guard let self, gen == self.generation, self.isSceneActive, !Task.isCancelled else { return }
            defer {
                if gen == self.generation, !Task.isCancelled {
                    self.isCommandInFlight = false
                    self.commandTask = nil
                }
            }
            do {
                try await operation(client)
                if gen == self.generation, !Task.isCancelled { self.lastError = nil }
            } catch {
                guard gen == self.generation, !Task.isCancelled else { return }
                if let apiError = error as? RemoteAPIError, case .cancelled = apiError { return }
                self.lastError = self.message(for: error)
            }
        }
    }

    private func invalidateCommand() {
        commandTask?.cancel()
        commandTask = nil
        isCommandInFlight = false
    }

    // MARK: - 音量 / 跳转

    func setVolumeAdjusting(_ adjusting: Bool) {
        isAdjustingVolume = adjusting
        if !adjusting { commitVolume(volumeDraft ?? currentVolume) }
    }

    func setSeekAdjusting(_ adjusting: Bool) {
        if adjusting {
            seekDragIdentity = SeekDragIdentity(songId: songId, generation: generation)
            seekDraftInvalidated = false
            isAdjustingSeek = true
        } else {
            isAdjustingSeek = false
            defer {
                seekDragIdentity = nil
                seekDraftInvalidated = false
            }
            // 曲目 / 连接已变化：手势失效，绝不提交旧草稿或回退位置。
            guard !seekDraftInvalidated else {
                seekDraft = nil
                return
            }
            commitSeek(seekDraft ?? Double(currentPositionMs))
        }
    }

    /// 拖动写入：手势失效后忽略，避免对替换后的曲目产生副作用。
    func updateSeekDraft(_ value: Double) {
        guard !seekDraftInvalidated else { return }
        seekDraft = value
    }

    /// 曲目 / 连接身份变化时作废进行中的拖动。
    private func invalidateSeekDragIfNeeded(newSongId: Int?) {
        guard isAdjustingSeek, let drag = seekDragIdentity else { return }
        if drag.songId != newSongId || drag.generation != generation {
            seekDraftInvalidated = true
            seekDraft = nil
        }
    }

    /// 静音 / 取消静音（恢复本地记忆的上一个非零音量）。只发一次请求。
    func toggleMute() {
        guard canControl else { return }
        let current = currentVolume
        if current > 0.001 {
            rememberedVolume = current
            commitVolume(0)
        } else {
            let restore = rememberedVolume > 0.001 ? rememberedVolume : 1
            commitVolume(restore)
        }
    }

    /// 按步进调整音量（例如 ±0.05）。
    func adjustVolume(by delta: Double) {
        guard canControl else { return }
        commitVolume(currentVolume + delta)
    }

    /// 直接设置音量预设（0...1）。
    func setVolumePreset(_ value: Double) {
        guard canControl else { return }
        commitVolume(value)
    }

    /// 相对跳转（秒），仅当已知有效时长时可用。
    func seekBy(seconds: Int) {
        guard canSeek else { return }
        let base = Double(currentPositionMs)
        let target = base + Double(seconds) * 1000
        commitSeek(target)
    }

    /// 跳到开头，仅当已知有效时长时可用。
    func seekToStart() {
        guard canSeek else { return }
        commitSeek(0)
    }

    private func commitVolume(_ raw: Double) {
        guard canControl else { return }
        guard raw.isFinite else { return }
        let value = min(max(raw, 0), 1)
        // 本地乐观更新：立即可见。Android 仍是最终权威，下一次快照会校准。
        if !isAdjustingVolume { volumeDraft = nil }
        nowPlaying?.volume = value
        status?.volume = value
        runControl { client in
            try await client.setVolume(value)
        }
    }

    private func commitSeek(_ raw: Double) {
        guard canControl else { return }
        guard raw.isFinite else { return }
        let duration = Double(currentDurationMs)
        let clamped = duration > 0 ? min(max(raw, 0), duration) : max(raw, 0)
        guard clamped.isFinite else { return }
        let position = max(0, safeInt(clamped))
        runControl { client in
            try await client.seek(positionMs: position)
        }
    }

    // MARK: - 进度锚点

    /// 用权威快照重建单调锚点。
    ///
    /// - 有权威位置：以它为基（钳制到 0...duration）；
    /// - 无权威位置（部分事件 / 冻结）：保留「当前显示位置」，绝不回退；
    /// - 仅在播放中、前台、数据新鲜且未缓冲时继续外推。
    private func updateProgressAnchor(authoritativePosition: Int? = nil) {
        let previous = progressAnchor
        let duration = Double(rawDurationMs)
        let base: Double
        if let authoritativePosition {
            base = Double(max(0, authoritativePosition))
        } else if let previous {
            base = previous.isAdvancing ? projectedPosition(from: previous, at: monotonicNow()) : previous.positionMs
        } else {
            base = Double(rawPositionMs)
        }
        let advancing = isAdvancingNow()
        let rate = (playbackRate.isFinite && playbackRate > 0) ? playbackRate : 1
        progressAnchor = ProgressAnchor(
            positionMs: clampToDuration(base, duration: duration),
            uptime: monotonicNow(),
            durationMs: duration,
            isAdvancing: advancing,
            rate: rate
        )
    }

    private func isAdvancingNow() -> Bool {
        playbackState == .playing && isSceneActive && !isStale && !isBuffering
    }

    private func projectedPosition(from anchor: ProgressAnchor, at now: TimeInterval) -> Double {
        let elapsedMs = (now - anchor.uptime) * 1000 * anchor.rate
        guard elapsedMs.isFinite, elapsedMs > 0 else { return anchor.positionMs }
        return anchor.positionMs + elapsedMs
    }

    private func clampToDuration(_ value: Double, duration: Double) -> Double {
        guard value.isFinite else { return 0 }
        let lower = max(value, 0)
        return duration > 0 ? min(lower, duration) : lower
    }

    /// 有限安全的 Double -> Int（含四舍五入与溢出保护）。
    private func safeInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value.rounded())
    }

    // MARK: - 错误文案

    func message(for error: Error) -> String {
        if let apiError = error as? RemoteAPIError {
            return apiError.errorDescription ?? "未知错误。"
        }
        if let validation = error as? HostValidator.ValidationError {
            return validation.errorDescription ?? "配置无效。"
        }
        return error.localizedDescription
    }
}
