#if canImport(ActivityKit)
import XCTest
import Foundation
@testable import SPlayerRemote

/// 交互式 intent：参数序列化契约、失败不谎报成功、授权会话门控。
final class IntentExecutionTests: XCTestCase {

    private func makeAuthorizedStore() -> RemoteIntentAuthorizedSessionStore {
        let store = RemoteIntentAuthorizedSessionStore()
        store.authorize(baseURL: URL(string: "http://192.168.31.100:6688/api/external")!, token: "t")
        return store
    }

    private func makeQueue(ids: [Int]) -> LanShareQueue {
        let tracks = ids.map { id in
            LanShareTrack(
                id: String(id),
                source: "netease",
                title: "Track \(id)",
                artists: [LanShareArtist(id: "1", name: "Artist")],
                album: nil,
                durationMs: 0,
                coverURL: nil
            )
        }
        return LanShareQueue(revision: 1, playIndex: 0, tracks: tracks)
    }

    // MARK: - F1 参数 / 错误

    func testIntentCommandIsParameterBacked() {
        let intent = RemoteControlIntent(command: .next)
        XCTAssertEqual(intent.command, "next")

        let mirror = Mirror(reflecting: intent)
        let commandChild = mirror.children.first { $0.label == "_command" }
        XCTAssertNotNil(commandChild, "command 必须由属性包装器承载（@Parameter）")
        if let commandChild {
            let typeName = String(describing: type(of: commandChild.value))
            XCTAssertTrue(typeName.contains("Parameter"), "command 必须是 @Parameter，实际：\(typeName)")
        }
    }

    func testDefaultIntentCommandIsEmptyAndInvalid() async {
        XCTAssertEqual(RemoteControlIntent().command, "")
        XCTAssertNil(RemoteCommand(rawValue: ""))

        let api = MockRemoteAPI()
        let feedback = RecordingIntentFeedback()
        do {
            try await RemoteIntentCommandExecutor.execute(
                rawCommand: "",
                sessionStore: makeAuthorizedStore(),
                clientFactory: { _, _ in api },
                feedback: feedback
            )
            XCTFail("空命令不应成功")
        } catch let error as RemoteActivityCommandError {
            XCTAssertEqual(error, .invalidCommand)
        } catch {
            XCTFail("未知错误：\(error)")
        }
        XCTAssertTrue(api.sentCommands.isEmpty)
    }

    func testInvalidCommandThrowsBeforeNetwork() async {
        let api = MockRemoteAPI()
        do {
            try await RemoteIntentCommandExecutor.execute(
                rawCommand: "rewind",
                sessionStore: makeAuthorizedStore(),
                clientFactory: { _, _ in api },
                feedback: RecordingIntentFeedback()
            )
            XCTFail("非法命令不应成功")
        } catch let error as RemoteActivityCommandError {
            XCTAssertEqual(error, .invalidCommand)
        } catch {
            XCTFail("未知错误：\(error)")
        }
        XCTAssertTrue(api.sentCommands.isEmpty, "非法命令不得发网络请求")
    }

    func testExtensionFallbackErrorIsFriendly() {
        XCTAssertNotNil(RemoteActivityCommandError.extensionUnavailable.errorDescription)
        XCTAssertTrue((RemoteActivityCommandError.extensionUnavailable.errorDescription ?? "").contains("App"))
    }

    // MARK: - F2 授权会话

    func testNoAuthorizedSessionThrowsAndSendsNothing() async {
        let api = MockRemoteAPI()
        let store = RemoteIntentAuthorizedSessionStore()
        let feedback = RecordingIntentFeedback()

        do {
            try await RemoteIntentCommandExecutor.execute(
                rawCommand: "next",
                sessionStore: store,
                clientFactory: { _, _ in api },
                feedback: feedback
            )
            XCTFail("无授权会话不应成功")
        } catch let error as RemoteActivityCommandError {
            XCTAssertEqual(error, .noAuthorizedSession)
        } catch {
            XCTFail("未知错误：\(error)")
        }
        XCTAssertTrue(api.sentCommands.isEmpty, "冷启动 / 无会话时不得用保存凭据发命令")
        XCTAssertTrue(feedback.applied.isEmpty)
    }

    func testInvalidatedSessionBeforeDispatchSendsNothing() async {
        let api = MockRemoteAPI()
        let store = makeAuthorizedStore()
        store.invalidate()

        do {
            try await RemoteIntentCommandExecutor.execute(
                rawCommand: "play",
                sessionStore: store,
                clientFactory: { _, _ in api },
                feedback: RecordingIntentFeedback()
            )
            XCTFail("失效会话不应成功")
        } catch let error as RemoteActivityCommandError {
            XCTAssertEqual(error, .noAuthorizedSession)
        } catch {
            XCTFail("未知错误：\(error)")
        }
        XCTAssertTrue(api.sentCommands.isEmpty)
    }

    func testSessionReplacementInvalidatesOldIdentity() {
        let store = RemoteIntentAuthorizedSessionStore()
        let old = store.authorize(baseURL: URL(string: "http://10.0.0.1:6688/api/external")!, token: "a")
        let new = store.authorize(baseURL: URL(string: "http://10.0.0.2:6688/api/external")!, token: "b")
        XCTAssertFalse(store.isCurrent(old))
        XCTAssertTrue(store.isCurrent(new))
    }

    // MARK: - 命令结果 / 刷新

    func testAckFailureThrowsWithoutRetryOrFeedback() async {
        let api = MockRemoteAPI()
        api.commandResult = .failure(RemoteAPIError.unexpectedResponse)
        let feedback = RecordingIntentFeedback()

        do {
            try await RemoteIntentCommandExecutor.execute(
                rawCommand: "next",
                sessionStore: makeAuthorizedStore(),
                clientFactory: { _, _ in api },
                feedback: feedback
            )
            XCTFail("未确认的命令不应成功")
        } catch let error as RemoteActivityCommandError {
            XCTAssertEqual(error, .deliveryFailed)
        } catch {
            XCTFail("未知错误：\(error)")
        }
        XCTAssertEqual(api.sentCommands, [.next], "只应尝试一次，绝不重试")
        XCTAssertTrue(feedback.applied.isEmpty)
    }

    func testSuccessRefreshesNowPlayingAndQueueMetadata() async throws {
        let api = MockRemoteAPI()
        api.nowPlayingResult = .success(NowPlayingResponse(songId: 8, paused: false, playing: true, buffering: false, position: 0, duration: 0, volume: 1))
        api.lanShareQueueResult = .success(makeQueue(ids: [42, 8]))
        let feedback = RecordingIntentFeedback()

        try await RemoteIntentCommandExecutor.execute(
            rawCommand: "next",
            sessionStore: makeAuthorizedStore(),
            clientFactory: { _, _ in api },
            feedback: feedback
        )

        XCTAssertEqual(api.sentCommands, [.next])
        let call = try XCTUnwrap(feedback.applied.last)
        XCTAssertEqual(call.nowPlaying?.songId, 8)
        XCTAssertEqual(call.track?.id, "8", "应解析队列中与新 songId 匹配的元数据")
        XCTAssertNotNil(call.authoritativeDate, "成功刷新应带权威时间")
    }

    func testRefreshFailureDoesNotReportFreshness() async throws {
        let api = MockRemoteAPI()
        api.statusResult = .failure(RemoteAPIError.transport("down"))
        api.nowPlayingResult = .failure(RemoteAPIError.transport("down"))
        api.lanShareQueueResult = .failure(RemoteAPIError.forbidden)
        let feedback = RecordingIntentFeedback()

        try await RemoteIntentCommandExecutor.execute(
            rawCommand: "pause",
            sessionStore: makeAuthorizedStore(),
            clientFactory: { _, _ in api },
            feedback: feedback
        )

        let call = try XCTUnwrap(feedback.applied.last)
        XCTAssertNil(call.authoritativeDate, "刷新失败不得伪造新鲜时间")
        XCTAssertNil(call.status)
        XCTAssertNil(call.nowPlaying)
    }

    /// R4：命令后只拿到 status、拿不到 now-playing 时不得报告新鲜。
    func testStatusOnlyPostCommandDoesNotReportFreshness() async throws {
        let api = MockRemoteAPI()
        api.statusResult = .success(StatusResponse(state: .paused, position: 0, duration: 0, volume: 1, isFinished: false))
        api.nowPlayingResult = .failure(RemoteAPIError.transport("down"))
        let feedback = RecordingIntentFeedback()

        try await RemoteIntentCommandExecutor.execute(
            rawCommand: "next",
            sessionStore: makeAuthorizedStore(),
            clientFactory: { _, _ in api },
            feedback: feedback
        )

        XCTAssertEqual(api.sentCommands, [.next])
        let call = try XCTUnwrap(feedback.applied.last)
        XCTAssertNotNil(call.status)
        XCTAssertNil(call.nowPlaying)
        XCTAssertNil(call.authoritativeDate, "缺少 now-playing 身份不得报告新鲜")
    }

    /// R1：刷新 await 期间会话失效 / 被替换时，绝不反馈旧会话结果。
    func testSessionInvalidatedDuringRefreshSuppressesFeedback() async throws {
        let api = MockRemoteAPI()
        let store = makeAuthorizedStore()
        let gate = AsyncGate()
        api.nowPlayingDelay = { await gate.wait() }
        let feedback = RecordingIntentFeedback()

        let task = Task {
            try? await RemoteIntentCommandExecutor.execute(
                rawCommand: "next",
                sessionStore: store,
                clientFactory: { _, _ in api },
                feedback: feedback
            )
        }

        var spins = 0
        while api.sentCommands.isEmpty && spins < 2_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertEqual(api.sentCommands, [.next])

        // 刷新仍在 await 中时替换 / 失效会话。
        store.invalidate()
        await gate.open()
        await task.value

        XCTAssertTrue(feedback.applied.isEmpty, "会话在刷新 await 期间失效不得反馈任何结果")
    }
}
#endif
