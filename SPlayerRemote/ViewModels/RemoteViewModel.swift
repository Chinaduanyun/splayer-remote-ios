import Foundation
import Combine

/// 连接与播放状态的中枢。所有 UI 状态变更都在主线程进行。
///
/// 设计要点（参见 IMPLEMENTATION.md）：
/// - 只有 info + status 都成功获取才认为连接成功；
/// - 场景激活且已连接时才轮询（约 2 秒一次）；只有一条轮询任务；
/// - 每次重连都会递增 `generation`，过期响应会被丢弃，不会覆盖新连接；
/// - 后台返回的轮询/连接结果一律丢弃，不能在后台启用命令；
/// - 命令请求互斥（`isCommandInFlight`）且被保留可取消，世代不符的旧完成不得改动状态；
/// - 轮询遇到非致命错误时保持重试但标记 `isStale`，在成功刷新前禁用控制。
@MainActor
final class RemoteViewModel: ObservableObject {

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var isConnected: Bool { self == .connected }
    }

    @Published private(set) var connection: ConnectionState = .disconnected
    @Published private(set) var info: InfoResponse?
    @Published private(set) var status: StatusResponse?
    @Published private(set) var nowPlaying: NowPlayingResponse?
    @Published private(set) var lastError: String?
    @Published private(set) var isCommandInFlight = false
    /// 最近一次刷新失败后的「数据可能过期」状态；成功刷新前禁用控制。
    @Published private(set) var isStale = false

    /// 滑杆草稿；为 nil 时表示跟随远端轮询值。
    @Published var volumeDraft: Double?
    @Published var seekDraft: Double?
    @Published private(set) var isAdjustingVolume = false
    @Published private(set) var isAdjustingSeek = false

    let settings: SettingsStore
    private let clientFactory: (URL, String) -> RemoteAPI
    private var client: RemoteAPI?
    private var pollTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var generation = 0
    private var isSceneActive = true
    private let pollIntervalNanoseconds: UInt64

    nonisolated init(
        settings: SettingsStore,
        clientFactory: @escaping (URL, String) -> RemoteAPI = { url, token in
            RemoteAPIClient(baseURL: url, token: token)
        },
        pollIntervalNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.settings = settings
        self.clientFactory = clientFactory
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    // MARK: - 派生状态

    /// 只有「场景激活 + 已连接 + 非过期 + 无命令在途」时才允许控制，
    /// 后台或数据过期一律禁用不安全控件。
    var canControl: Bool {
        isSceneActive && connection.isConnected && !isStale && !isCommandInFlight
    }

    /// 当前用于 UI 显示的播放状态。
    var playbackState: PlaybackState {
        if let nowPlaying, nowPlaying.playing { return .playing }
        if let nowPlaying, nowPlaying.buffering { return .buffering }
        return status?.state ?? .unknown
    }

    var currentPositionMs: Int {
        nowPlaying?.position ?? status?.position ?? 0
    }

    var currentDurationMs: Int {
        nowPlaying?.duration ?? status?.duration ?? 0
    }

    var currentVolume: Double {
        nowPlaying?.volume ?? status?.volume ?? 1
    }

    // MARK: - 连接生命周期

    func connect() async {
        disconnect(resetState: false)

        let baseURL: URL
        do {
            baseURL = try settings.makeBaseURL()
        } catch {
            connection = .failed(message(for: error))
            lastError = message(for: error)
            return
        }

        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let newClient = clientFactory(baseURL, token)

        generation += 1
        let gen = generation
        client = newClient
        connection = .connecting
        lastError = nil
        isStale = false
        status = nil
        nowPlaying = nil

        do {
            // info 与 status 都必须成功，才认为连接“好”。
            let fetchedInfo = try await newClient.fetchInfo()
            let fetchedStatus = try await newClient.fetchStatus()

            // 连接被新的 connect/disconnect 取代：静默退出。
            guard gen == generation else { return }
            // 连接在后台完成：不启用命令，回到断开态，前台恢复时需重连。
            guard isSceneActive else {
                finishConnectAfterBackground()
                return
            }
            info = fetchedInfo
            status = fetchedStatus

            let fetchedNow = try? await newClient.fetchNowPlaying()
            guard gen == generation else { return }
            guard isSceneActive else {
                finishConnectAfterBackground()
                return
            }
            nowPlaying = fetchedNow

            connection = .connected
            isStale = false
            lastError = nil
            startPolling()
        } catch {
            guard gen == generation else { return }
            client = nil
            connection = .failed(message(for: error))
            lastError = message(for: error)
        }
    }

    /// 连接在后台期间完成：不保留客户端、不启用命令。
    private func finishConnectAfterBackground() {
        client = nil
        connection = .disconnected
        isStale = false
        lastError = nil
    }

    func disconnect(resetState: Bool = true) {
        generation += 1
        stopPolling()
        invalidateCommand()
        client = nil
        if resetState {
            connection = .disconnected
            info = nil
            status = nil
            nowPlaying = nil
            volumeDraft = nil
            seekDraft = nil
            lastError = nil
            isStale = false
            isAdjustingVolume = false
            isAdjustingSeek = false
        }
    }

    /// 由场景阶段驱动：进入后台时取消所有网络工作；回到前台且已连接时恢复轮询。
    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        if active {
            if connection.isConnected { startPolling() }
        } else {
            generation += 1
            isStale = true
            stopPolling()
            invalidateCommand()
            volumeDraft = nil
            seekDraft = nil
            isAdjustingVolume = false
            isAdjustingSeek = false
            if connection == .connecting {
                client = nil
                connection = .disconnected
            }
        }
    }

    // MARK: - 轮询

    private func startPolling() {
        stopPolling()
        guard isSceneActive, client != nil else { return }
        let gen = generation
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.pollIntervalNanoseconds
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
        do {
            async let statusTask = client.fetchStatus()
            async let nowTask = client.fetchNowPlaying()
            let (freshStatus, freshNow) = try await (statusTask, nowTask)

            // 丢弃过期或后台返回的响应，避免覆盖新连接 / 后台状态。
            guard gen == generation, isSceneActive, !Task.isCancelled else { return }
            status = freshStatus
            nowPlaying = freshNow
            if !isAdjustingVolume { volumeDraft = nil }
            if !isAdjustingSeek { seekDraft = nil }
            if !connection.isConnected { connection = .connected }
            isStale = false
            lastError = nil
        } catch {
            guard gen == generation, isSceneActive, !Task.isCancelled else { return }
            if let apiError = error as? RemoteAPIError, case .cancelled = apiError { return }
            if isFatal(error) {
                // 401/403：连接已失效，停止轮询并进入失败态。
                stopPolling()
                invalidateCommand()
                isStale = true
                connection = .failed(message(for: error))
                lastError = message(for: error)
            } else {
                // 非致命（网络等）：保持轮询自动重试，但标记数据过期以禁用控制。
                isStale = true
                lastError = message(for: error)
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

    /// 统一的控制请求执行器：互斥、可取消、带世代保护。
    ///
    /// - 进入前要求 `canControl`（即已连接、场景激活、非过期、无命令在途）；
    /// - 会取消上一条仍在途的命令任务；
    /// - 完成时仅在世代未变时才清除忙标志/写入错误，避免旧完成影响新连接。
    private func runControl(_ operation: @escaping (RemoteAPI) async throws -> Void) {
        guard canControl, let client else { return }
        let gen = generation
        commandTask?.cancel()
        isCommandInFlight = true
        commandTask = Task { @MainActor [weak self] in
            guard let self, gen == self.generation, self.isSceneActive, !Task.isCancelled else { return }
            defer {
                if gen == self.generation {
                    self.isCommandInFlight = false
                    self.commandTask = nil
                }
            }
            do {
                try await operation(client)
                if gen == self.generation { self.lastError = nil }
            } catch {
                guard gen == self.generation else { return }
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
        if !adjusting { commitVolume() }
    }

    func setSeekAdjusting(_ adjusting: Bool) {
        isAdjustingSeek = adjusting
        if !adjusting { commitSeek() }
    }

    private func commitVolume() {
        guard canControl else { return }
        let raw = volumeDraft ?? currentVolume
        guard raw.isFinite else { return }
        let value = min(max(raw, 0), 1)
        runControl { client in
            try await client.setVolume(value)
        }
    }

    private func commitSeek() {
        guard canControl else { return }
        guard let raw = seekDraft, raw.isFinite else { return }
        let duration = Double(currentDurationMs)
        let clamped = duration > 0 ? min(max(raw, 0), duration) : max(raw, 0)
        guard clamped.isFinite else { return }
        let position = Int(clamped.rounded())
        runControl { client in
            try await client.seek(positionMs: position)
        }
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
