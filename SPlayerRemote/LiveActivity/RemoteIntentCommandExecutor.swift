import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// 交互式 Live Activity intent 的 **App 进程** 实现。
///
/// 安全与稳健：
/// - 只使用 App 进程内存中的**已授权会话**（连接成功后登记），绝不回退到“已保存配置”；
///   冷启动且没有有效会话时直接抛出友好错误，要求用户回到 App 内连接；
/// - 派发前再次校验会话身份；断开 / 关闭实时活动 / 连接替换 / 致命鉴权失败会**同步**失效会话；
/// - 一次 intent 只发起**一次**有界 HTTP 命令（客户端 8s 超时），成功后不再重试命令；
/// - 命令完成后尽力拉取 status + now-playing（可选队列元数据）刷新 Activity；刷新失败不伪造新鲜度。
enum RemoteIntentCommandExecutor {

    static func perform(rawCommand: String) async throws {
        try await execute(
            rawCommand: rawCommand,
            sessionStore: .shared,
            clientFactory: { url, token in RemoteAPIClient(baseURL: url, token: token) },
            feedback: ActivityIntentFeedback(sessionStore: .shared)
        )
    }

    /// 可测试入口：注入会话、客户端与反馈。
    static func execute(
        rawCommand: String,
        sessionStore: RemoteIntentAuthorizedSessionStore,
        clientFactory: (URL, String) -> RemoteAPI,
        feedback: RemoteIntentFeedbackApplying
    ) async throws {
        guard let command = RemoteCommand(rawValue: rawCommand) else {
            throw RemoteActivityCommandError.invalidCommand
        }
        let acquired = await RemoteIntentGate.shared.acquire()
        guard acquired else {
            throw RemoteActivityCommandError.deliveryFailed
        }

        do {
            try await performLocked(
                command: command,
                sessionStore: sessionStore,
                clientFactory: clientFactory,
                feedback: feedback
            )
        } catch {
            await RemoteIntentGate.shared.release()
            throw error
        }
        await RemoteIntentGate.shared.release()
    }

    private static func performLocked(
        command: RemoteCommand,
        sessionStore: RemoteIntentAuthorizedSessionStore,
        clientFactory: (URL, String) -> RemoteAPI,
        feedback: RemoteIntentFeedbackApplying
    ) async throws {
        guard let session = sessionStore.current() else {
            throw RemoteActivityCommandError.noAuthorizedSession
        }
        let client = clientFactory(session.baseURL, session.token)

        // 派发前立即校验会话身份：失效后绝不发送。
        guard sessionStore.isCurrent(session.id) else {
            throw RemoteActivityCommandError.noAuthorizedSession
        }

        do {
            try await client.send(command: command)
        } catch {
            throw RemoteActivityCommandError.deliveryFailed
        }

        // 命令已提交（传输层）；只在会话仍有效时刷新展示，绝不重试命令。
        guard sessionStore.isCurrent(session.id) else { return }

        let status = try? await client.fetchStatus()
        let nowPlaying = try? await client.fetchNowPlaying()
        // 播放数据成功即捕获权威时间戳 —— 必须先于可选的队列拉取，避免元数据延迟污染新鲜度。
        // 仅当拿到 now-playing 身份时才认为“新鲜”：status-only 不得把旧曲目标为刚更新。
        let authoritativeDate: Date? = (nowPlaying != nil) ? Date() : nil

        // 刷新 await 之后**再次校验**会话身份：期间断开 / 替换 / 关闭实时活动都绝不反馈。
        guard sessionStore.isCurrent(session.id) else { return }

        let queue = try? await client.fetchLanShareQueue()
        guard sessionStore.isCurrent(session.id) else { return }
        let track = queue?.matchingTrack(songId: nowPlaying?.songId)
        await feedback.apply(
            sessionId: session.id,
            status: status,
            nowPlaying: nowPlaying,
            track: track,
            authoritativeDate: authoritativeDate
        )
    }
}

/// 纯函数构建器：便于对“新曲目清除旧元数据 / 刷新失败不伪造新鲜度”做确定性测试。
enum RemoteIntentFeedbackBuilder {
    static func makeState(
        existing: RemoteActivityAttributes.ContentState,
        status: StatusResponse?,
        nowPlaying: NowPlayingResponse?,
        track: LanShareTrack?,
        authoritativeDate: Date?
    ) -> RemoteActivityAttributes.ContentState {
        var state = existing

        if let newSongId = nowPlaying.map({ String($0.songId) }) {
            if newSongId != existing.songId {
                // 曲目已切换：不要保留上一首的标题 / 艺人。
                state.songId = RemoteActivityLimits.truncated(newSongId, limit: RemoteActivityLimits.songId)
                state.title = RemoteActivityLimits.truncated(track?.title ?? "", limit: RemoteActivityLimits.title)
                state.artist = RemoteActivityLimits.truncated(track?.artistLine ?? "", limit: RemoteActivityLimits.artist)
            } else if let track {
                state.title = RemoteActivityLimits.truncated(track.title ?? state.title, limit: RemoteActivityLimits.title)
                state.artist = RemoteActivityLimits.truncated(track.artistLine ?? state.artist, limit: RemoteActivityLimits.artist)
            }
        }

        if let status {
            state.isPlaying = status.state == .playing
            state.isBuffering = status.state == .buffering
        } else if let nowPlaying {
            state.isPlaying = nowPlaying.playing
            state.isBuffering = nowPlaying.buffering
        }

        if let authoritativeDate {
            state.lastUpdate = authoritativeDate
            state.connectionAvailable = true
        } else {
            // 刷新失败：保留旧时间戳（可能已过期），并明确连接不可用。
            state.connectionAvailable = false
        }
        return state
    }
}

/// 生产反馈：只更新**属于该授权会话**的 Activity；绝不新建 Activity。
/// 每次更新前都重新校验**同一个**授权会话存储，确保 await 期间失效 / 替换后不再写入旧反馈。
/// 会话替换后旧的 Activity 内容状态带有旧 sessionID，因此不会被旧刷新覆盖。
struct ActivityIntentFeedback: RemoteIntentFeedbackApplying {
    let sessionStore: RemoteIntentAuthorizedSessionStore

    func apply(
        sessionId: UUID,
        status: StatusResponse?,
        nowPlaying: NowPlayingResponse?,
        track: LanShareTrack?,
        authoritativeDate: Date?
    ) async {
        for activity in Activity<RemoteActivityAttributes>.activities {
            // 逐目标边界：当前授权会话仍有效 + 目标 Activity 属于该会话，二者缺一不可。
            guard ActivityFeedbackBoundary.shouldUpdate(
                sessionId: sessionId,
                sessionIDInActivity: activity.contentState.sessionID,
                isSessionCurrent: { sessionStore.isCurrent($0) }
            ) else { continue }
            let state = RemoteIntentFeedbackBuilder.makeState(
                existing: activity.contentState,
                status: status,
                nowPlaying: nowPlaying,
                track: track,
                authoritativeDate: authoritativeDate
            )
            let staleDate = state.lastUpdate.addingTimeInterval(RemoteActivityLimits.staleInterval)
            await activity.update(ActivityContent(state: state, staleDate: staleDate))
            // 每个 await 之后重新评估：下一个目标必须再次通过当前授权检查。
        }
    }
}

#endif

/// 生产 Activity 反馈的逐目标授权边界（纯函数，便于确定性测试）。
/// 必须同时满足：
/// 1. 注入的会话存储此刻仍认为该会话有效（在每次 update 前重新求值）；
/// 2. Activity 内容里的不透明 sessionID 与该会话 ID 完全一致。
enum ActivityFeedbackBoundary {
    static func shouldUpdate(
        sessionId: UUID,
        sessionIDInActivity: String,
        isSessionCurrent: (UUID) -> Bool
    ) -> Bool {
        guard isSessionCurrent(sessionId) else { return false }
        return sessionIDInActivity == sessionId.uuidString
    }
}

// MARK: - App 进程内的会话授权（不依赖 ActivityKit 类型）

/// 串行去重：同一时刻只允许一个 intent 命令在途，避免连点造成重复请求。
actor RemoteIntentGate {
    static let shared = RemoteIntentGate()
    private var busy = false

    func acquire() -> Bool {
        if busy { return false }
        busy = true
        return true
    }

    func release() {
        busy = false
    }
}

/// App 进程内“已授权 intent 会话”。
///
/// 凭据只存在于内存，绝不进入 Activity 内容状态。App 进程被终止后（冷启动）此会话为空，
/// 锁屏按钮会得到“请先打开 App 连接”的友好失败，而不会用保存的凭据发起远程命令。
///
/// 使用短临界区锁而非 MainActor：`invalidate()` 必须能在显式断开时**同步**完成。
struct RemoteIntentAuthorizedSession: Sendable {
    let id: UUID
    let baseURL: URL
    let token: String
}

final class RemoteIntentAuthorizedSessionStore {
    static let shared = RemoteIntentAuthorizedSessionStore()

    private let lock = NSLock()
    private var session: RemoteIntentAuthorizedSession?

    /// 登记新会话（连接成功且用户已启用实时活动时调用）。
    @discardableResult
    func authorize(baseURL: URL, token: String) -> UUID {
        let id = UUID()
        lock.lock()
        session = RemoteIntentAuthorizedSession(id: id, baseURL: baseURL, token: token)
        lock.unlock()
        return id
    }

    /// 同步失效：断开 / 关闭实时活动 / 连接替换 / 致命鉴权失败时立即调用。
    func invalidate() {
        lock.lock()
        session = nil
        lock.unlock()
    }

    func current() -> RemoteIntentAuthorizedSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    func isCurrent(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return session?.id == id
    }
}

/// 命令完成后的 Activity 反馈抽象（可注入以便确定性测试）。
protocol RemoteIntentFeedbackApplying {
    func apply(
        sessionId: UUID,
        status: StatusResponse?,
        nowPlaying: NowPlayingResponse?,
        track: LanShareTrack?,
        authoritativeDate: Date?
    ) async
}
