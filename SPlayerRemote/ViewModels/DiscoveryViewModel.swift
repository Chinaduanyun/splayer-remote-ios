import Foundation
import Combine

@MainActor
final class DiscoveryViewModel: ObservableObject {
    @Published private(set) var capabilities: DiscoveryCapabilities?
    @Published private(set) var selection: DiscoverySelection?
    @Published private(set) var playlists: [DiscoveryPlaylist] = []
    @Published private(set) var message = "连接增强安卓版后可浏览推荐。"
    @Published private(set) var busy = false
    @Published private(set) var commandPending = false
    private struct UnresolvedCommand {
        let command: UUID
        let session: String
        let generation: Int
        let mutation: Int
        let api: DiscoveryAPI
    }
    private var unresolved: UnresolvedCommand?
    @Published private(set) var needsReconciliation = false
    private var epoch = 0
    private var api: DiscoveryAPI?
    private var boundGeneration = -1
    private var selectionSession: String?
    private var selectionReceived: Date?
    private var activePath = "discovery/daily-songs"
    private var activeOffset = 0
    private let factory: (ConnectionConfiguration) -> DiscoveryAPI
    private let pollLimit: Int
    private let now: () -> Date
    private let sleep: () async throws -> Void
    init(factory: @escaping (ConnectionConfiguration) -> DiscoveryAPI = { DiscoveryAPIClient(configuration: $0) }, now: @escaping () -> Date = Date.init,
         pollLimit: Int = 20, sleep: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) }) {
        self.factory = factory; self.now = now; self.sleep = sleep
        self.pollLimit = max(0, min(20, pollLimit))
    }
    func invalidate() {
        epoch += 1
        api = nil; capabilities = nil; selection = nil; playlists = []
        selectionSession = nil; selectionReceived = nil; busy = false
        message = commandPending ? "连接或账号会话已变更，结果未知；不会重新提交。" : "请连接增强安卓版。"
    }
    func connect(remote: RemoteViewModel) async {
        invalidate()
        guard let configuration = remote.discoveryConfiguration else { return }
        boundGeneration = remote.generation
        let client = factory(configuration)
        api = client
        let identity = epoch
        busy = true
        defer { if identity == epoch { busy = false } }
        do {
            let caps = try await client.get("capabilities", query: [], as: DiscoveryCapabilities.self)
            guard identity == epoch, boundGeneration == remote.generation else { return }
            guard caps.protocolVersion == 1 else { throw DiscoveryFailure(status: 404, code: "") }
            capabilities = caps
            message = caps.accountState == "signedIn" ? "选择推荐类型；心动是普通智能列表，不会开启持久心动模式。" : "请先在增强安卓版登录账号。"
        } catch { if identity == epoch { message = safeMessage(error) } }
    }
    func query(_ path: String, offset: Int = 0) async {
        guard !busy, !commandPending, let api, let caps = capabilities else { return }
        let identity = epoch
        busy = true
        selection = nil; selectionSession = nil; selectionReceived = nil; playlists = []
        defer { if identity == epoch { busy = false } }
        do {
            // Recheck account/session before every query; no selection survives a session change.
            let fresh = try await api.get("capabilities", query: [], as: DiscoveryCapabilities.self)
            guard identity == epoch else { return }
            guard fresh.serverSessionId == caps.serverSessionId, fresh.accountState == caps.accountState else {
                invalidate(); message = "账号或会话已变更，请重新连接发现。"; return
            }
            activePath = path; activeOffset = offset
            if path == "discovery/recommended-playlists" {
                struct Playlists: Decodable { let items: [DiscoveryPlaylist] }
                let response = try await api.get(path, query: [], as: Playlists.self)
                guard identity == epoch else { return }
                guard response.items.count <= 100 else { throw DiscoveryFailure(status: 413, code: "") }
                playlists = response.items
            } else {
                let params = path.contains("/tracks") ? [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "100")] : []
                let response = try await api.get(path, query: params, as: DiscoverySelection.self)
                guard identity == epoch else { return }
                guard response.items.count <= 100 else { throw DiscoveryFailure(status: 413, code: "") }
                selection = response; selectionSession = fresh.serverSessionId; selectionReceived = now()
                playlists = []
            }
            message = "仅播放本次返回的当前页，最多 100 首；选择有效期 5 分钟。"
        } catch { if identity == epoch { message = safeMessage(error) } }
    }
    func playlist(_ id: String) async {
        guard !id.isEmpty, id.count <= 20, id.first != "0", id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return }
        await query("discovery/playlists/\(id)/tracks")
    }
    func nextPage() async {
        guard let offset = selection?.nextOffset, offset >= 0, offset <= 1_000_000 else { return }
        await query(activePath, offset: offset)
    }
    func retryQuery() async { await query(activePath, offset: activeOffset) }
    func play(_ index: Int, remote: RemoteViewModel) async {
        guard !commandPending, !busy, let api, let caps = capabilities, let selection,
              selectionSession == caps.serverSessionId, boundGeneration == remote.generation,
              let received = selectionReceived, now().timeIntervalSince(received) < 300,
              selection.playable(index: index, now: now()), let lease = remote.acquireDiscoveryCommand() else {
            message = "选择已过期或控制忙碌，请刷新查询后再明确选择。"; return
        }
        commandPending = true
        let identity = epoch
        let commandGeneration = remote.generation
        let command = UUID() // Created once per explicit action; never reused or replayed.
        defer { commandPending = false; remote.releaseDiscoveryCommand(lease) }
        message = "正在提交一次队列替换请求…"
        var mutation: Int?
        await { () async -> Void in
        do {
            let fresh = try await api.get("capabilities", query: [], as: DiscoveryCapabilities.self)
            guard identity == epoch, commandGeneration == remote.generation, remote.discoveryConfiguration != nil, !Task.isCancelled,
                  fresh.serverSessionId == caps.serverSessionId, fresh.accountState == caps.accountState else {
                message = "会话已变更，未提交。请刷新推荐。"; self.selection = nil; return
            }
            guard let barrier = remote.beginDiscoveryQueueMutation(lease) else { return }
            mutation = barrier
            unresolved = UnresolvedCommand(command: command, session: caps.serverSessionId, generation: commandGeneration, mutation: barrier, api: api)
            needsReconciliation = true
            var state = try await api.submit(session: caps.serverSessionId, selection: selection.selectionId, index: index, command: command)
            for attempt in 0...pollLimit {
                guard identity == epoch, commandGeneration == remote.generation, remote.discoveryConfiguration != nil else {
                    message = "会话已变更，结果未知；不会重新提交。"; return
                }
                guard state.commandId == command else { break }
                switch state.state {
                case "applied":
                    guard state.result?.queueApplied == true else { break }
                    remote.resolveDiscoveryQueueMutation(barrier, generation: commandGeneration)
                    unresolved = nil; needsReconciliation = false
                    self.selection = nil
                    let evidence = await remote.refreshPlaybackEvidence()
                    guard identity == epoch, commandGeneration == remote.generation, remote.discoveryConfiguration != nil, !Task.isCancelled else { return }
                    let confirmed = evidence.map { String($0.songId) } == state.result?.selectedTrackId && evidence?.playing == true
                    message = confirmed ? "队列已应用；当前播放状态已确认。" : "队列已应用；尚未确认播放，请查看正在播放。"
                    return
                case "rejected", "expired":
                    remote.resolveDiscoveryQueueMutation(barrier, generation: commandGeneration)
                    unresolved = nil; needsReconciliation = false
                    self.selection = nil
                    message = state.error == "SELECTION_EXPIRED" ? "选择已过期，请重新查询。" : "队列请求被拒绝或已过期，请检查 Android 授权与前台状态。"
                    return
                case "unknown": message = "结果未知；不会重新提交，请查看当前队列。"; self.selection = nil; return
                case "pending", "executing": message = "请求已接收，等待队列应用（不代表播放成功）…"
                default: break
                }
                if attempt == pollLimit { break }
                try await sleep()
                state = try await api.get("commands/\(command.uuidString)", query: [URLQueryItem(name: "serverSessionId", value: caps.serverSessionId)], as: DiscoveryCommandStatus.self)
            }
            message = "等待超时，结果未知；不会重新提交，请查看当前队列。"
        } catch {
            message = "结果未知；不会重新提交。" + safeMessage(error)
        }
        self.selection = nil
        }()
        if let mutation {
            await remote.finishDiscoveryQueueMutation(mutation, generation: commandGeneration)
        }
    }
    /// Query only the original UUID. Unknown/lost/pending is never proof of completion.
    func reconcile(remote: RemoteViewModel) async {
        guard !commandPending, let pending = unresolved else { return }
        guard pending.generation == remote.generation, remote.discoveryConfiguration != nil else {
            message = "连接已变更，原命令结果未知；队列暂只读，不会重新提交。"
            return
        }
        commandPending = true
        defer { commandPending = false }
        do {
            for attempt in 0..<max(1, pollLimit) {
                let state = try await pending.api.get("commands/\(pending.command.uuidString)", query: [URLQueryItem(name: "serverSessionId", value: pending.session)], as: DiscoveryCommandStatus.self)
                guard pending.generation == remote.generation, remote.discoveryConfiguration != nil, !Task.isCancelled,
                      state.commandId == pending.command else { return }
                if ["applied", "rejected", "expired"].contains(state.state) {
                    remote.resolveDiscoveryQueueMutation(pending.mutation, generation: pending.generation)
                    await remote.finishDiscoveryQueueMutation(pending.mutation, generation: pending.generation)
                    guard pending.generation == remote.generation else { return }
                    unresolved = nil; needsReconciliation = false
                    message = state.state == "applied" ? "队列已应用；尚未确认播放。" : "命令已结束，请刷新推荐后再选择。"
                    return
                }
                if state.state == "unknown" { break }
                if attempt + 1 < max(1, pollLimit) { try await sleep() }
            }
        } catch { /* Preserve unresolved identity and persistent read-only barrier. */ }
        message = "原命令结果仍未知，队列暂只读；可重新查询状态，绝不重新提交。"
    }

    private func safeMessage(_ error: Error) -> String {
        (error as? DiscoveryFailure)?.message ?? "网络或响应异常，请检查连接；仅可重试查询。"
    }
}
