import Foundation
import Combine

/// 连接与播放状态的中枢。所有 UI 状态变更都在主线程进行。
///
/// 设计要点（参见 IMPLEMENTATION.md）：
/// - 只有 info + status 都成功获取才认为连接成功；
/// - 场景激活且已连接时才轮询（约 2 秒一次）；只有一条轮询任务；
/// - 每次重连都会递增 `generation`，过期响应会被丢弃，不会覆盖新连接；
/// - 命令请求互斥（`isCommandInFlight`），不会自动重试（上游 next/prev 为异步派发）；
/// - 拖动滑杆只改本地草稿，松手才发请求，不按 tick 发送。
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

    /// 滑杆草稿；为 nil 时表示跟随远端轮询值。
    @Published var volumeDraft: Double?
    @Published var seekDraft: Double?
    @Published private(set) var isAdjustingVolume = false
    @Published private(set) var isAdjustingSeek = false

    let settings: SettingsStore
    private let tokenStore: TokenStoring
    private let clientFactory: (URL, String) -> RemoteAPI
    private var client: RemoteAPI?
    private var pollTask: Task<Void, Never>?
    private var generation = 0
    private var isSceneActive = true

    private let pollIntervalNanoseconds: UInt64 = 2_000_000_000

    nonisolated init(
        settings: SettingsStore,
        tokenStore: TokenStoring = KeychainTokenStore(),
        clientFactory: @escaping (URL, String) -> RemoteAPI = { url, token in
            RemoteAPIClient(baseURL: url, token: token)
        }
    ) {
        self.settings = settings
        self.tokenStore = tokenStore
        self.clientFactory = clientFactory
    }

    // MARK: - 派生状态

    var canControl: Bool {
        connection.isConnected && !isCommandInFlight
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
        status = nil
        nowPlaying = nil

        do {
            // info 与 status 都必须成功，才认为连接“好”。
            let fetchedInfo = try await newClient.fetchInfo()
            let fetchedStatus = try await newClient.fetchStatus()
            guard gen == generation else { return }
            info = fetchedInfo
            status = fetchedStatus

            let fetchedNow = try? await newClient.fetchNowPlaying()
            guard gen == generation else { return }
            nowPlaying = fetchedNow

            connection = .connected
            lastError = nil
            startPolling()
        } catch {
            guard gen == generation else { return }
            client = nil
            connection = .failed(message(for: error))
            lastError = message(for: error)
        }
    }

    func disconnect(resetState: Bool = true) {
        generation += 1
        stopPolling()
        client = nil
        if resetState {
            connection = .disconnected
            info = nil
            status = nil
            nowPlaying = nil
            volumeDraft = nil
            seekDraft = nil
            lastError = nil
        }
    }

    /// 由场景阶段驱动：进入后台时取消所有在网络工作；回到前台且已连接时恢复轮询。
    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        if active {
            if connection.isConnected { startPolling() }
        } else {
            stopPolling()
        }
    }

    // MARK: - 轮询

    private func startPolling() {
        stopPolling()
        guard isSceneActive, client != nil else { return }
        let gen = generation
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.pollIntervalNanoseconds ?? 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.pollOnce(expectedGeneration: gen)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce(expectedGeneration gen: Int) async {
        guard gen == generation, let client else { return }
        do {
            async let statusTask = client.fetchStatus()
            async let nowTask = client.fetchNowPlaying()
            let (freshStatus, freshNow) = try await (statusTask, nowTask)

            // 丢弃过期响应：只有仍属于当前连接世代时才应用。
            guard gen == generation else { return }
            status = freshStatus
            nowPlaying = freshNow
            if !isAdjustingVolume { volumeDraft = nil }
            if !isAdjustingSeek { seekDraft = nil }
            if !connection.isConnected { connection = .connected }
            lastError = nil
        } catch {
            guard gen == generation else { return }
            if let apiError = error as? RemoteAPIError, case .cancelled = apiError { return }
            lastError = message(for: error)
            // 鉴权类错误意味着连接已失效：停止轮询并进入失败态。
            if isFatal(error) {
                stopPolling()
                connection = .failed(message(for: error))
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
        guard canControl, let client else { return }
        isCommandInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCommandInFlight = false }
            do {
                try await client.send(command: command)
                self.lastError = nil
            } catch {
                self.lastError = self.message(for: error)
            }
        }
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
        guard canControl, let client else { return }
        let raw = volumeDraft ?? currentVolume
        guard raw.isFinite else { return }
        let value = min(max(raw, 0), 1)
        isCommandInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCommandInFlight = false }
            do {
                try await client.setVolume(value)
                self.lastError = nil
            } catch {
                self.lastError = self.message(for: error)
            }
        }
    }

    private func commitSeek() {
        guard canControl, let client else { return }
        guard let raw = seekDraft, raw.isFinite else { return }
        let duration = Double(currentDurationMs)
        let clamped = duration > 0 ? min(max(raw, 0), duration) : max(raw, 0)
        guard clamped.isFinite else { return }
        isCommandInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCommandInFlight = false }
            do {
                try await client.seek(positionMs: Int(clamped.rounded()))
                self.lastError = nil
            } catch {
                self.lastError = self.message(for: error)
            }
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
