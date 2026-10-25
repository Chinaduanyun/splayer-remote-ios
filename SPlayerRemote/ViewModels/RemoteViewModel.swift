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

    /// 协作控制通道状态（与只读的外部实时 WS **相互独立**）。
    enum CollaborationState: Equatable {
        case disabled
        case unauthorized
        case connecting
        case live
        case unavailable

        var displayName: String {
            switch self {
            case .disabled: return "未启用"
            case .unauthorized: return "未授权"
            case .connecting: return "连接中"
            case .live: return "可控"
            case .unavailable: return "不可用"
            }
        }

        var canSendCommands: Bool { self == .live }
    }

    /// 场景阶段：区分 `.inactive`（控制中心 / 切换器过渡）与真正的 `.background`。
    /// `.inactive` 尽力保留健康的会话；只有 `.background` 才暂停长时间网络工作。
    enum ScenePhaseState: Equatable {
        case active
        case inactive
        case background
    }

    /// 局域网分享元数据的可用性（与控制能力完全解耦）。
    enum MetadataState: Equatable {
        case idle
        case loading
        case available
        case unavailable
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

    // MARK: - 局域网分享元数据（只读，诚实地报告可用性）

    /// 队列快照（`/api/lanShare/getQueue`）。`nil` 表示尚未获取或不可用。
    @Published private(set) var queue: LanShareQueue?
    /// 队列安装世代：每次安装 / 清空新队列递增（不可变选择据此校验收渲染快照）。
    @Published private(set) var queueGeneration = 0
    /// 按外部 `songId` 匹配到的当前曲目（绝不依赖可能过期的 `playIndex`）。
    @Published private(set) var currentTrack: LanShareTrack?
    /// 当前曲目歌词（`/api/lanShare/getLyric`）。
    @Published private(set) var lyric: LanShareLyricDocument?
    /// 元数据可用性；绝不与控制能力或 REST 健康度耦合。
    @Published private(set) var metadataState: MetadataState = .idle
    /// 最近一次元数据错误（仅面向用户的简短文案，不含原始响应）。
    @Published private(set) var metadataError: String?

    // MARK: - 协作控制（授权后才可点播；与只读元数据解耦）

    /// `/api/lanShare/getStatus` 的最近结果；仅在授权条件下包含内存级 wsToken。
    @Published private(set) var collaborationStatus: LanShareStatus?
    /// 协作通道状态；仅 `.live` 时允许从队列点播。
    @Published private(set) var collaborationState: CollaborationState = .disabled
    /// 队列点播的待确认状态；仅用于本地提示，绝不重发命令。
    @Published private(set) var pendingPlayback: CollaborationPendingPlayback?
    /// 面向用户的协作提示（不含 token / URL）。
    @Published private(set) var collaborationMessage: String?

    /// 滑杆草稿；为 nil 时表示跟随远端轮询值。
    @Published var volumeDraft: Double?
    @Published var seekDraft: Double?
    @Published private(set) var isAdjustingVolume = false
    @Published private(set) var isAdjustingSeek = false
    /// 本地记忆的「取消静音」音量；**不是**手机系统音量。
    @Published private(set) var rememberedVolume: Double = 0.5

    private let settings: SettingsStore
    private let clientFactory: (URL, String) -> RemoteAPI
    private let socketFactory: RemoteSocketFactory?
    private let collaborationSocketFactory: CollaborationSocketFactory?
    private var client: RemoteAPI?
    private var socket: RemoteSocket?
    private var pollTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    @Published private(set) var generation = 0
    @Published private(set) var discoveryCommandLease: UUID?

    /// Only the captured, successfully connected configuration; never settings drafts.
    var discoveryConfiguration: ConnectionConfiguration? {
        connection.isConnected && isSceneActive ? activeConfiguration : nil
    }
    func acquireDiscoveryCommand() -> UUID? {
        guard !queueMutationBlocked, canControl else { return nil }
        let lease = UUID()
        discoveryCommandLease = lease
        return lease
    }
    private var queueMutationEpoch = 0
    private var queueMutationBlocked = false
    private var resolvedQueueMutationEpoch: Int?
    private var resolvedQueueMutationGeneration: Int?

    /// Only a matching terminal command observation establishes ordering.
    func resolveDiscoveryQueueMutation(_ epoch: Int, generation gen: Int) {
        guard epoch == queueMutationEpoch, gen == generation, isSceneActive else { return }
        resolvedQueueMutationEpoch = epoch
        resolvedQueueMutationGeneration = gen
    }

    func beginDiscoveryQueueMutation(_ lease: UUID) -> Int? {
        guard discoveryCommandLease == lease else { return nil }
        queueMutationEpoch += 1
        resolvedQueueMutationEpoch = nil
        resolvedQueueMutationGeneration = nil
        queueMutationBlocked = true
        queueFreshnessGeneration = -1
        queueGeneration += 1
        return queueMutationEpoch
    }

    /// Await an eligible post-barrier snapshot; failure must not restore old indices.
    func finishDiscoveryQueueMutation(_ epoch: Int, generation gen: Int) async {
        guard epoch == queueMutationEpoch, resolvedQueueMutationEpoch == epoch,
              resolvedQueueMutationGeneration == gen, gen == generation, isSceneActive,
              connection.isConnected, let client else { return }
        do {
            let snapshot = try await client.fetchLanShareQueue()
            guard epoch == queueMutationEpoch, gen == generation, isSceneActive,
                  connection.isConnected, !Task.isCancelled, let snapshot else { return }
            queue = snapshot
            queueGeneration += 1
            queueFreshnessGeneration = gen
            queueMutationBlocked = false
            metadataState = .available
            recomputeCurrentTrack()
        } catch { /* Keep point-play read-only on ambiguous or failed refresh. */ }
    }

    func releaseDiscoveryCommand(_ lease: UUID) {
        if discoveryCommandLease == lease { discoveryCommandLease = nil }
    }
    private var socketGeneration = 0
    private var reconnectAttempt = 0
    private var scenePhase: ScenePhaseState = .active
    private var wasBackgrounded = false
    private var suppressAutoConnect = false
    /// 致命鉴权失败（401/403）后锁定自动重连，直到显式 connect 或提交新配置。
    private var authenticationFailureLatched = false

    /// 元数据请求世代 / 互斥，避免重叠或迟到的响应覆盖新曲目。
    private var metadataGeneration = 0
    private var isMetadataFetchInFlight = false
    private var pendingMetadataRefresh = false
    private var metadataTrackId: Int?
    private var lastMetadataAttempt: Date?
    private let metadataRetryInterval: TimeInterval

    /// 回前台后立即刷新（不先睡眠）；断开 / 后台时取消。
    private var foregroundRefreshTask: Task<Void, Never>?

    /// Live Activity 呈现（可空：测试与未启用时为空实现 / nil）。
    private let liveActivity: LiveActivityPresenting?
    /// intent 授权会话存储（App 进程内存；冷启动为空）。
    private let intentSessionStore: RemoteIntentAuthorizedSessionStore?
    /// 场景是否不处于后台（`.active` 与 `.inactive` 均视为前台）。
    private var isSceneActive: Bool { scenePhase != .background }

    /// 授权状态请求身份：递增即作废旧响应；`active...` 为当前在途请求身份。
    private var collaborationStatusRequestID = 0
    private var activeCollaborationStatusRequestID: Int?
    private var collaborationSocket: CollaborationSocket?
    private var collaborationSocketGeneration = 0
    private var pendingPlaybackTask: Task<Void, Never>?
    private let collaborationTimeoutNanoseconds: UInt64
    /// 队列在哪个连接世代被成功刷新；前台恢复后、刷新完成前保持不可点播。
    private var queueFreshnessGeneration = -1

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
        collaborationSocketFactory: CollaborationSocketFactory? = nil,
        wsPollIntervalNanoseconds: UInt64 = 5_000_000_000,
        reconnectDelays: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000, 8_000_000_000],
        metadataRetryInterval: TimeInterval = 15,
        collaborationTimeoutNanoseconds: UInt64 = 12_000_000_000,
        liveActivity: LiveActivityPresenting? = nil,
        intentSessionStore: RemoteIntentAuthorizedSessionStore? = nil,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        dateProvider: @escaping () -> Date = { Date() }
    ) {
        self.settings = settings
        self.clientFactory = clientFactory
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.socketFactory = socketFactory
        self.collaborationSocketFactory = collaborationSocketFactory
        self.wsPollIntervalNanoseconds = wsPollIntervalNanoseconds
        self.reconnectDelays = reconnectDelays.isEmpty ? [1_000_000_000] : reconnectDelays
        self.metadataRetryInterval = metadataRetryInterval
        self.collaborationTimeoutNanoseconds = collaborationTimeoutNanoseconds
        self.liveActivity = liveActivity
        self.intentSessionStore = intentSessionStore
        self.monotonicNow = monotonicNow
        self.dateProvider = dateProvider
    }

    // MARK: - 派生状态

    /// 只有「场景激活 + 已连接 + 非过期 + 无命令在途 + 无待确认点播」时才允许控制，
    /// 后台、数据过期或点播待确认一律禁用不安全控件。
    var canControl: Bool {
        isSceneActive && connection.isConnected && !isStale && !isCommandInFlight && pendingPlayback == nil && discoveryCommandLease == nil
    }

    /// 仅在已知有效时长时允许跳转。
    var canSeek: Bool { canControl && currentDurationMs > 0 }

    /// 仅在「可控制 + REST 健康 + 当前世代队列已刷新 + 协作通道可控」时才允许从队列点播。
    /// 与 HTTP 控制共享 `canControl` 互斥，避免同时提交两条命令。
    var canSelectFromQueue: Bool {
        canControl
            && restAvailable
            && !queueMutationBlocked
            && queueFreshnessGeneration == generation
            && collaborationState == .live
            && metadataState == .available
            && !(queue?.tracks.isEmpty ?? true)
    }

    /// 队列只读时的说明文案；可控时为 nil。
    var queueReadOnlyHint: String? {
        guard metadataState == .available, queue != nil else { return nil }
        if canSelectFromQueue { return nil }
        switch collaborationState {
        case .live:
            if !restAvailable { return "REST 数据已降级，队列暂时只读。" }
            if queueMutationBlocked { return "队列替换结果需重新确认，当前队列暂只读；请在发现中查询原命令状态。" }
            if queueFreshnessGeneration != generation { return "队列尚未在当前连接中刷新，暂时只读。" }
            return canControl ? "可点播当前队列中的曲目。" : "数据过期或场景不可用，暂时无法点播。"
        case .connecting:
            return "正在建立协作通道，稍后可点播当前队列。"
        case .unauthorized:
            return "当前设备未获得主机的协作授权，队列为只读浏览。可在设置中重试授权。"
        case .disabled:
            return "主机未开启局域网协作，队列为只读浏览。"
        case .unavailable:
            return "协作通道不可用，队列为只读浏览；可重试授权。"
        }
    }

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
        authenticationFailureLatched = false
        disconnect(resetState: false)
        // 新建连接即替换旧会话：结束旧 Activity，避免其内容 / 按钮指向旧连接。
        liveActivity?.end()
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
              !authenticationFailureLatched,
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
        resetMetadata()
        resetCollaboration()

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
            authorizeIntentSession()
            liveActivity?.setUserEnabled(settings.liveActivityEnabled)
            recomputeCurrentTrack()
            refreshMetadata(force: true)
            notifyLiveActivity()
            // 授权判定只在同一次连接的主机 + 凭据上进行；未授权时队列保持只读。
            Task { @MainActor [weak self] in await self?.refreshCollaborationStatus() }
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            client = nil
            connection = .failed(message(for: error))
            lastError = message(for: error)
            invalidateIntentSession()
            if isAuthenticationFailure(error) { authenticationFailureLatched = true }
            resetCollaboration()
            liveActivity?.end()
        }
    }

    /// 连接在后台期间完成：不保留客户端、不启用命令。
    private func finishConnectAfterBackground() {
        client = nil
        activeConfiguration = nil
        connection = .disconnected
        isStale = false
        lastError = nil
        invalidateIntentSession()
    }

    func disconnect(resetState: Bool = true) {
        // 连接世代变化：立即作废任何进行中的拖动手势，旧手势释放不得提交到新连接。
        if isAdjustingSeek || seekDragIdentity != nil {
            seekDraftInvalidated = true
        }
        generation += 1
        connectionTask?.cancel()
        connectionTask = nil
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        stopPolling()
        teardownSocket()
        invalidateCommand()
        invalidateIntentSession()
        resetCollaboration()
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
            // 不重置 seekDraftInvalidated：保留对旧手势释放的拦截，直到下一次 begin 重置。
            wsClientCount = nil
            lastSuccessfulUpdate = nil
            lastSuccessfulRestUpdate = nil
            playbackRate = 1
            isReady = nil
            remoteErrorCode = nil
            progressAnchor = nil
            trackedSongId = nil
            resetMetadata()
            liveActivity?.end()
        }
    }

    /// 用户主动断开：同时抑制后续前台自动重连，直到再次手动连接；结束 Live Activity。
    func disconnectByUser() {
        suppressAutoConnect = true
        liveActivity?.end()
        disconnect()
    }

    /// 兼容入口：`active == true` 等价 `.active`，`false` 等价 `.background`。
    func setSceneActive(_ active: Bool) {
        setScenePhase(active ? .active : .background)
    }

    /// 由场景阶段驱动。
    ///
    /// - `.inactive`（控制中心 / 切换器过渡）：尽力保留健康会话，不动网络。
    /// - `.background`：按 iOS 要求暂停长时间网络工作，但**不丢弃**已鉴权的逻辑会话与不可变配置。
    /// - `.active`：若刚从后台回来且逻辑上仍连接，立即刷新一次 HTTP（不先睡眠）并恢复实时通道。
    func setScenePhase(_ phase: ScenePhaseState) {
        guard scenePhase != phase else { return }
        let wentBackground = phase == .background
        scenePhase = phase
        switch phase {
        case .active:
            handleForeground()
        case .inactive:
            break // 尽力保留健康会话。
        case .background:
            handleBackground()
        }
        if wentBackground { wasBackgrounded = true }
    }

    private func handleBackground() {
        generation += 1
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        stopPolling()
        teardownSocket()
        invalidateCommand()
        teardownCollaborationSocket()
        invalidatePendingPlayback()
        invalidateCollaborationStatusRequest()
        collaborationState = .disabled
        queueFreshnessGeneration = -1
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

    private func handleForeground() {
        // 仅当确实经历过后台才需要恢复；`.inactive` -> `.active` 保持现状。
        guard wasBackgrounded else { return }
        wasBackgrounded = false
        guard connection.isConnected, client != nil else { return }
        updateProgressAnchor()
        startPolling()
        startSocketIfNeeded()
        ensureIntentSessionAuthorized()
        // 回前台重新确认协作授权（不可用时队列保持只读）。
        Task { @MainActor [weak self] in await self?.refreshCollaborationStatus() }
        // 后台中断的元数据请求在回前台后恢复（不依赖下一次 track 变化）。
        refreshMetadata(force: true)
        // 立即刷新一次 HTTP（不先睡眠 2/5 秒）；世代 / 前台门控保证安全。
        let gen = generation
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pollOnce(expectedGeneration: gen)
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
            // 仅「完整且合法」的快照才能恢复播放新鲜度；partial / 非法时间不得清除过期。
            if payload.isFreshPlaybackSnapshot {
                isStale = false
                lastSuccessfulUpdate = dateProvider()
                lastError = nil
            }
            applyStateChanged(payload)
            // 排序屏障独立于新鲜度：任何已合并的共享字段 partial 都必须阻止旧轮询覆盖。
            if payload.mutatesSharedState {
                wsArrivalCount += 1
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
                handleMetadataTrackChange()
            }
            confirmPendingPlayback(songId: songId)
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
        notifyLiveActivity()
    }

    /// `ended` 没有 data：不制造位置，只把状态收敛为非播放并冻结在当前位置。
    private func applyEnded() {
        nowPlaying?.playing = false
        nowPlaying?.buffering = false
        nowPlaying?.paused = true
        status?.state = .paused
        status?.isFinished = true
        updateProgressAnchor()
        notifyLiveActivity()
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
        _ = await pollOnce(expectedGeneration: generation)
    }

    func refreshPlaybackEvidence() async -> NowPlayingResponse? {
        await pollOnce(expectedGeneration: generation)
    }

    @discardableResult
    private func pollOnce(expectedGeneration gen: Int) async -> NowPlayingResponse? {
        guard gen == generation, let client else { return nil }
        let wsArrivalAtStart = wsArrivalCount
        do {
            async let statusTask = client.fetchStatus()
            async let nowTask = client.fetchNowPlaying()
            let (freshStatus, freshNow) = try await (statusTask, nowTask)

            // 丢弃过期或后台返回的响应，避免覆盖新连接 / 后台状态。
            guard gen == generation, isSceneActive, !Task.isCancelled else { return nil }
            // 已有更新的 WS 快照（含 ended）到达：丢弃这次较早发起的轮询。
            guard wsArrivalCount == wsArrivalAtStart else { return nil }

            status = freshStatus
            nowPlaying = freshNow
            let previousSongId = trackedSongId
            trackedSongId = freshNow.songId
            if freshNow.songId != previousSongId {
                invalidateSeekDragIfNeeded(newSongId: freshNow.songId)
                handleMetadataTrackChange()
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
            notifyLiveActivity()
            confirmPendingPlayback(songId: freshNow.songId)
            scheduleMetadataCalibrationIfNeeded()
            return freshNow
        } catch {
            guard gen == generation, isSceneActive, !Task.isCancelled else { return nil }
            if let apiError = error as? RemoteAPIError, case .cancelled = apiError { return nil }
            if isFatal(error) {
                // 401/403：连接已失效，停止轮询与 socket 并进入失败态。
                stopPolling()
                teardownSocket()
                invalidateCommand()
                invalidateIntentSession()
                resetCollaboration()
                if isAuthenticationFailure(error) { authenticationFailureLatched = true }
                isStale = true
                isRestDegraded = true
                connection = .failed(message(for: error))
                lastError = message(for: error)
                liveActivity?.end()
            } else {
                // 非致命（网络等）：保持轮询自动重试，但标记数据过期并冻结进度（不回退）。
                isStale = true
                isRestDegraded = true
                lastError = message(for: error)
                updateProgressAnchor()
                notifyLiveActivity()
            }
        }
        return nil
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

    /// 仅鉴权失败（401/403）触发自动重连锁存；配置错误不冒充鉴权失败。
    private func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let apiError = error as? RemoteAPIError else { return false }
        switch apiError {
        case .unauthorized, .forbidden:
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
            let gesture = seekDragIdentity
            let invalidated = seekDraftInvalidated
            isAdjustingSeek = false
            seekDragIdentity = nil
            seekDraftInvalidated = false
            // 手势失效：绝不提交旧草稿或回退位置。
            guard !invalidated else {
                seekDraft = nil
                return
            }
            // 释放时必须同时匹配捕获的连接世代与曲目，否则视为旧连接/旧曲目的手势。
            if let gesture {
                guard gesture.generation == generation, gesture.songId == songId else {
                    seekDraft = nil
                    return
                }
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

    // MARK: - 局域网分享元数据（只读）

    /// 手动刷新元数据（下拉刷新 / 诊断 / 测试）。会等待本次拉取完成。
    func refreshMetadataNow() async {
        if queueMutationBlocked {
            guard discoveryCommandLease == nil else { return }
            await finishDiscoveryQueueMutation(queueMutationEpoch, generation: generation)
            return
        }
        if isMetadataFetchInFlight {
            pendingMetadataRefresh = true
            return
        }
        await performMetadataFetch(force: true)
    }

    /// 触发一次元数据拉取（节流 + 互斥 + 合并）；不阻塞调用方。
    func refreshMetadata(force: Bool = false) {
        guard isSceneActive, connection.isConnected, client != nil else { return }
        if isMetadataFetchInFlight {
            // 合并：强制刷新或曲目已变化时，等当前请求结束再补一次，避免重叠。
            if force || metadataTrackId != songId {
                pendingMetadataRefresh = true
            }
            return
        }
        if !force, let last = lastMetadataAttempt, dateProvider().timeIntervalSince(last) < metadataRetryInterval {
            return
        }
        Task { @MainActor [weak self] in
            await self?.performMetadataFetch(force: force)
        }
    }

    /// 用户切换锁屏实时活动；权限不可用时优雅降级。
    func setLiveActivityEnabled(_ enabled: Bool) {
        settings.setLiveActivityEnabled(enabled)
        liveActivity?.setUserEnabled(enabled)
        if enabled {
            authorizeIntentSession()
            notifyLiveActivity()
        } else {
            invalidateIntentSession()
            liveActivity?.end()
        }
    }

    var liveActivityEnabled: Bool { settings.liveActivityEnabled }

    /// 连接成功后登记 intent 授权会话（仅当已连接 + 用户开启实时活动）。
    private func authorizeIntentSession() {
        guard let intentSessionStore else { return }
        guard connection.isConnected,
              let configuration = activeConfiguration,
              settings.liveActivityEnabled else {
            intentSessionStore.invalidate()
            return
        }
        intentSessionStore.authorize(baseURL: configuration.baseURL, token: configuration.token)
    }

    /// 前台恢复：会话仍存在则保持不变；不存在且条件满足时重新登记。
    private func ensureIntentSessionAuthorized() {
        guard let intentSessionStore else { return }
        guard connection.isConnected,
              let configuration = activeConfiguration,
              settings.liveActivityEnabled else {
            intentSessionStore.invalidate()
            return
        }
        if intentSessionStore.current() == nil {
            intentSessionStore.authorize(baseURL: configuration.baseURL, token: configuration.token)
        }
    }

    private func invalidateIntentSession() {
        intentSessionStore?.invalidate()
    }

    /// 曲目变化：立即作废上一首歌词，按需排队 / 触发一次新元数据拉取。
    private func handleMetadataTrackChange() {
        lyric = nil
        recomputeCurrentTrack()
        refreshMetadata(force: true)
    }

    private func scheduleMetadataCalibrationIfNeeded() {
        // 已可用也做低频校准；节流与在途合并由 refreshMetadata 负责。
        refreshMetadata(force: false)
    }

    /// 串行拉取队列 + 歌词；连接世代 + 请求世代 + 前台 + 曲目身份门控。
    private func performMetadataFetch(force: Bool) async {
        guard isSceneActive, connection.isConnected, let client else { return }
        if isMetadataFetchInFlight { return }
        if !force, let last = lastMetadataAttempt, dateProvider().timeIntervalSince(last) < metadataRetryInterval {
            return
        }
        isMetadataFetchInFlight = true
        metadataGeneration += 1
        let requestGen = metadataGeneration
        let connectionGen = generation
        let mutationEpoch = queueMutationEpoch
        let eligibleQueueRead = !queueMutationBlocked
        let requestTrackId = songId
        metadataTrackId = requestTrackId
        if metadataState == .idle { metadataState = .loading }
        defer {
            if requestGen == metadataGeneration {
                isMetadataFetchInFlight = false
                if pendingMetadataRefresh {
                    pendingMetadataRefresh = false
                    Task { @MainActor [weak self] in
                        await self?.performMetadataFetch(force: true)
                    }
                }
            }
        }

        func isCurrent() -> Bool {
            requestGen == metadataGeneration && connectionGen == generation && isSceneActive && mutationEpoch == queueMutationEpoch
        }

        do {
            let fetchedQueue = try await client.fetchLanShareQueue()
            guard isCurrent(), mutationEpoch == queueMutationEpoch, eligibleQueueRead, !queueMutationBlocked else { return }
            lastMetadataAttempt = dateProvider()
            if let fetchedQueue {
                queue = fetchedQueue
                queueGeneration += 1
                queueFreshnessGeneration = connectionGen
                metadataState = .available
                metadataError = nil
                recomputeCurrentTrack()
            } else {
                // ok:false：诚实进入不可用，不保留过期展示。
                clearMetadataPresentation()
                queueGeneration += 1
                queueFreshnessGeneration = -1
                metadataState = .unavailable
            }
        } catch {
            guard isCurrent(), mutationEpoch == queueMutationEpoch, eligibleQueueRead, !queueMutationBlocked else { return }
            lastMetadataAttempt = dateProvider()
            clearMetadataPresentation()
            queueGeneration += 1
            queueFreshnessGeneration = -1
            metadataState = .unavailable
            metadataError = message(for: error)
        }

        // 歌词是曲目专属：仅在曲目身份未变时安装。
        do {
            let fetchedLyric = try await client.fetchLanShareLyric()
            guard isCurrent(), requestTrackId == songId else { return }
            lyric = fetchedLyric
        } catch {
            guard isCurrent(), requestTrackId == songId else { return }
            lyric = nil
        }
        notifyLiveActivity()
    }

    private func clearMetadataPresentation() {
        queue = nil
        currentTrack = nil
        lyric = nil
    }

    /// 按外部 `songId` 重新匹配当前曲目（不依赖可能过期的 `playIndex`）。
    private func recomputeCurrentTrack() {
        let matched = queue?.matchingTrack(songId: songId)
        if matched != currentTrack { currentTrack = matched }
    }

    private func resetMetadata() {
        metadataGeneration += 1
        isMetadataFetchInFlight = false
        pendingMetadataRefresh = false
        metadataTrackId = nil
        queue = nil
        queueGeneration += 1
        queueFreshnessGeneration = -1
        currentTrack = nil
        lyric = nil
        metadataState = .idle
        metadataError = nil
        lastMetadataAttempt = nil
    }

    // MARK: - 协作控制（授权后才可点播）

    /// 拉取 `/api/lanShare/getStatus` 并根据授权结果建立 / 关闭协作通道。
    /// 响应必须同时匹配：请求身份、连接世代、同一主机与前台状态；旧响应 / 旧失败一律丢弃。
    func refreshCollaborationStatus() async {
        guard isSceneActive, connection.isConnected, client != nil,
              let configuration = activeConfiguration else { return }
        // 同一世代同一时刻只允许一个授权请求。
        guard activeCollaborationStatusRequestID == nil else { return }
        let connectionGen = generation
        collaborationStatusRequestID += 1
        let requestID = collaborationStatusRequestID
        activeCollaborationStatusRequestID = requestID
        defer {
            if activeCollaborationStatusRequestID == requestID {
                activeCollaborationStatusRequestID = nil
            }
        }
        guard let client else { return }

        do {
            let status = try await client.fetchLanShareStatus()
            guard requestID == collaborationStatusRequestID,
                  activeCollaborationStatusRequestID == requestID,
                  connectionGen == generation,
                  isSceneActive,
                  connection.isConnected,
                  configuration.baseURL == activeConfiguration?.baseURL else { return }
            collaborationStatus = status
            if status.canCollaborate {
                startCollaborationSocket(configuration: configuration, token: status.wsToken ?? "")
            } else {
                teardownCollaborationSocket()
                invalidatePendingPlayback()
                collaborationState = (status.enabled && status.collabEnabled) ? .unauthorized : .disabled
            }
        } catch {
            guard requestID == collaborationStatusRequestID,
                  activeCollaborationStatusRequestID == requestID,
                  connectionGen == generation,
                  isSceneActive,
                  connection.isConnected else { return }
            teardownCollaborationSocket()
            invalidatePendingPlayback()
            collaborationState = .unavailable
            collaborationMessage = "无法获取协作授权状态，元数据仍可浏览。"
        }
    }

    /// 手动重试授权（设置 / 诊断 / 队列面板）。
    func retryCollaborationAuthorization() {
        guard connection.isConnected, client != nil else { return }
        Task { @MainActor [weak self] in await self?.refreshCollaborationStatus() }
    }

    /// 由 UI 在渲染行时构建不可变选择；无主机原始下标时返回 nil（不可点播）。
    func makeQueueSelection(for track: LanShareTrack) -> QueueSelectionIdentity? {
        guard let queue, let upstreamIndex = track.upstreamIndex else { return nil }
        return QueueSelectionIdentity(
            trackId: track.id,
            source: track.source,
            upstreamIndex: upstreamIndex,
            revision: queue.revision,
            queueGeneration: queueGeneration,
            connectionGeneration: generation
        )
    }

    /// 点播一个不可变选择：与当前连接 / 队列逐项比对后，只发送一次 playAt。
    /// 使用主机原始下标（`upstreamIndex`），绝不使用可能被丢弃行压缩过的展示下标。
    func playQueueItem(_ selection: QueueSelectionIdentity) {
        guard canSelectFromQueue, let queue else { return }
        guard selection.connectionGeneration == generation,
              selection.queueGeneration == queueGeneration,
              selection.revision == queue.revision else {
            collaborationMessage = "队列已更新，请刷新后重试。"
            return
        }
        guard let track = queue.tracks.first(where: { $0.upstreamIndex == selection.upstreamIndex }) else {
            collaborationMessage = "该曲目已不在当前队列中。"
            return
        }
        // 行身份 + 来源必须仍匹配该主机下标，避免同 id / 不同来源 / 重复 id 误播。
        guard track.id == selection.trackId,
              (track.source ?? "").caseInsensitiveCompare(selection.source ?? "") == .orderedSame else {
            collaborationMessage = "队列已更新，请刷新后重试。"
            return
        }
        guard let socket = collaborationSocket, socket.state == .open else {
            collaborationMessage = "协作通道尚未就绪，请稍后重试。"
            return
        }
        guard pendingPlayback == nil else { return }

        let timestamp = Int(dateProvider().timeIntervalSince1970 * 1000)
        guard let body = CollaborationCommand.playAt(index: selection.upstreamIndex, timestampMs: timestamp),
              let text = String(data: body, encoding: .utf8) else { return }

        // 先占用共享命令槽（pending），再派发；失败 / 超时 / 取消都必须释放且绝不重发。
        pendingPlayback = CollaborationPendingPlayback(
            trackId: selection.trackId,
            index: selection.upstreamIndex,
            revision: selection.revision,
            sentAt: dateProvider()
        )
        collaborationMessage = nil
        guard socket.send(text: text) else {
            invalidatePendingPlayback()
            collaborationMessage = "协作通道暂时不可用，请重试。"
            return
        }
        beginPendingPlaybackTimeout()
    }

    private func startCollaborationSocket(configuration: ConnectionConfiguration, token: String) {
        guard !token.isEmpty else { return }
        guard let factory = collaborationSocketFactory else {
            collaborationState = .unavailable
            return
        }
        if let existing = collaborationSocket, existing.state == .open || existing.state == .connecting {
            return
        }
        teardownCollaborationSocket()
        collaborationSocketGeneration += 1
        let gen = collaborationSocketGeneration
        guard let url = APIRequestFactory.collaborationWebSocketRequest(baseURL: configuration.baseURL, wsToken: token)?.url else {
            collaborationState = .unavailable
            return
        }
        let socket = factory(url)
        socket.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleCollaborationState(state, generation: gen) }
        }
        collaborationSocket = socket
        collaborationState = .connecting
        socket.start()
    }

    private func handleCollaborationState(_ state: RemoteSocketState, generation gen: Int) {
        guard gen == collaborationSocketGeneration else { return }
        switch state {
        case .open:
            guard isSceneActive, connection.isConnected else {
                teardownCollaborationSocket()
                return
            }
            collaborationState = .live
        case .closed:
            // 非预期关闭：世代安全地彻底 teardown，并作废待确认（绝不重放）。
            teardownCollaborationSocket()
            invalidatePendingPlayback()
            collaborationMessage = "协作通道已断开，队列暂时只读。"
            collaborationState = (collaborationStatus?.canCollaborate == true) ? .unavailable : .disabled
        case .idle, .connecting:
            break
        }
    }

    private func teardownCollaborationSocket() {
        collaborationSocketGeneration += 1
        collaborationSocket?.onStateChange = nil
        collaborationSocket?.stop()
        collaborationSocket = nil
    }

    /// 断开 / 后台 / 连接替换：关闭协作通道并作废待确认（**绝不重放命令**）。
    private func resetCollaboration() {
        teardownCollaborationSocket()
        invalidatePendingPlayback()
        invalidateCollaborationStatusRequest()
        collaborationStatus = nil
        collaborationState = .disabled
        collaborationMessage = nil
    }

    /// 作废在途授权状态请求：旧响应 / 旧失败不得影响新连接或新世代。
    private func invalidateCollaborationStatusRequest() {
        collaborationStatusRequestID += 1
        activeCollaborationStatusRequestID = nil
    }

    private func beginPendingPlaybackTimeout() {
        pendingPlaybackTask?.cancel()
        let timeout = collaborationTimeoutNanoseconds
        pendingPlaybackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard let self, !Task.isCancelled else { return }
            guard self.pendingPlayback != nil else { return }
            self.pendingPlayback = nil
            self.collaborationMessage = "未在限定时间内确认切歌结果，请查看当前播放状态。"
        }
    }

    /// 仅在权威 now-playing 身份命中期望曲目时清除待确认；绝不重发。
    private func confirmPendingPlayback(songId: Int?) {
        guard let pending = pendingPlayback else { return }
        guard let songId, String(songId) == pending.trackId else { return }
        pendingPlayback = nil
        collaborationMessage = nil
        pendingPlaybackTask?.cancel()
        pendingPlaybackTask = nil
    }

    private func invalidatePendingPlayback() {
        pendingPlaybackTask?.cancel()
        pendingPlaybackTask = nil
        pendingPlayback = nil
    }

    /// 通知 Live Activity；去重 / 限频由 presenter 负责。
    private func notifyLiveActivity() {
        guard let liveActivity else { return }
        let snapshot = RemoteActivitySnapshot(
            title: RemoteActivityLimits.truncated(currentTrack?.title ?? "SPlayer", limit: RemoteActivityLimits.title),
            artist: RemoteActivityLimits.truncated(currentTrack?.artistLine ?? "", limit: RemoteActivityLimits.artist),
            songId: RemoteActivityLimits.truncated(songId.map { String($0) } ?? "", limit: RemoteActivityLimits.songId),
            isPlaying: playbackState == .playing,
            isBuffering: isBuffering,
            connectionAvailable: connection.isConnected && !isStale,
            // 只使用最近一次权威播放成功时间；绝不因通知 / 失败尝试伪造新鲜度。
            timestamp: lastSuccessfulUpdate ?? Date.distantPast,
            // 不透明随机会话标识（非凭据）：让命令反馈只命中当前授权会话的 Activity。
            sessionID: intentSessionStore?.current()?.id.uuidString ?? ""
        )
        liveActivity.startOrUpdate(snapshot)
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
