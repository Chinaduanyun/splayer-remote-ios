import XCTest
@testable import SPlayerRemote

/// Live Activity 数据契约：内容状态只包含允许字段，绝不泄漏主机 / Token / URL。
final class LiveActivityModelTests: XCTestCase {

    private let allowedLabels: Set<String> = [
        "title", "artist", "songId", "isPlaying", "isBuffering", "lastUpdate", "connectionAvailable", "sessionID",
    ]

    private func makeSnapshot() -> RemoteActivitySnapshot {
        RemoteActivitySnapshot(
            title: "Example song",
            artist: "Example artist",
            songId: "42",
            isPlaying: true,
            isBuffering: false,
            connectionAvailable: true,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testContentStateExposesOnlyAllowedFields() {
        let state = RemoteActivityAttributes.ContentState(snapshot: makeSnapshot())
        let labels = Set(Mirror(reflecting: state).children.compactMap(\.label))
        XCTAssertEqual(labels, allowedLabels)

        let forbidden = ["token", "host", "url", "credential", "secret", "password", "port"]
        for label in labels {
            for word in forbidden {
                XCTAssertFalse(label.lowercased().contains(word), "内容状态不得包含字段：\(label)")
            }
        }
    }

    func testContentStateStringValuesContainNoURLsOrSecrets() {
        let state = RemoteActivityAttributes.ContentState(snapshot: makeSnapshot())
        for child in Mirror(reflecting: state).children {
            if let value = child.value as? String {
                XCTAssertFalse(value.contains("://"), "内容状态不得包含原始 URL：\(value)")
                XCTAssertFalse(value.lowercased().contains("token"))
            }
        }
    }

    func testSnapshotMapsToContentState() {
        let state = RemoteActivityAttributes.ContentState(snapshot: makeSnapshot())
        XCTAssertEqual(state.title, "Example song")
        XCTAssertEqual(state.artist, "Example artist")
        XCTAssertEqual(state.songId, "42")
        XCTAssertTrue(state.isPlaying)
        XCTAssertFalse(state.isBuffering)
        XCTAssertTrue(state.connectionAvailable)
    }

    func testContentStateTruncatesToConservativeActivityBudget() {
        let long = String(repeating: "x", count: 1_000)
        let snapshot = RemoteActivitySnapshot(
            title: long,
            artist: long,
            songId: long,
            isPlaying: true,
            isBuffering: false,
            connectionAvailable: true,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let state = RemoteActivityAttributes.ContentState(snapshot: snapshot)
        XCTAssertEqual(state.title.count, RemoteActivityLimits.title)
        XCTAssertEqual(state.artist.count, RemoteActivityLimits.artist)
        XCTAssertEqual(state.songId.count, RemoteActivityLimits.songId)
    }

    func testControlCommandsMapToRemoteCommands() {
        for command in RemoteControlCommand.allCases {
            XCTAssertNotNil(RemoteCommand(rawValue: command.rawValue), "命令 \(command.rawValue) 必须映射到 RemoteCommand")
        }
        XCTAssertEqual(RemoteCommand(rawValue: RemoteControlCommand.next.rawValue), .next)
        XCTAssertEqual(RemoteCommand(rawValue: RemoteControlCommand.previous.rawValue), .prev)
    }

    func testIntentCarriesCommandRawValue() {
        XCTAssertEqual(RemoteControlIntent(command: .next).command, "next")
        XCTAssertEqual(RemoteControlIntent(command: .play).command, "play")
        XCTAssertEqual(RemoteControlIntent(command: .pause).command, "pause")
        XCTAssertEqual(RemoteControlIntent(command: .previous).command, "prev")
    }

    func testAttributesCarryNoSensitiveStaticState() {
        let attributes = RemoteActivityAttributes(activityName: "SPlayer 播放")
        let labels = Set(Mirror(reflecting: attributes).children.compactMap(\.label))
        XCTAssertEqual(labels, ["activityName"])
        for label in labels {
            XCTAssertFalse(label.lowercased().contains("token"))
            XCTAssertFalse(label.lowercased().contains("host"))
        }
    }

    // MARK: - F8：生产反馈的逐目标授权边界

    private func makeSession() -> (RemoteIntentAuthorizedSessionStore, UUID) {
        let store = RemoteIntentAuthorizedSessionStore()
        let id = store.authorize(
            baseURL: URL(string: "http://example.invalid/api/external")!,
            token: "synthetic-token"
        )
        return (store, id)
    }

    func testFeedbackBoundaryRequiresCurrentSession() {
        let (store, id) = makeSession()
        XCTAssertTrue(ActivityFeedbackBoundary.shouldUpdate(
            sessionId: id,
            sessionIDInActivity: id.uuidString,
            isSessionCurrent: store.isCurrent
        ))

        store.invalidate()
        XCTAssertFalse(ActivityFeedbackBoundary.shouldUpdate(
            sessionId: id,
            sessionIDInActivity: id.uuidString,
            isSessionCurrent: store.isCurrent
        ), "失效会话不得反馈旧 Activity")
    }

    func testFeedbackBoundaryRejectsReplacementTarget() {
        let store = RemoteIntentAuthorizedSessionStore()
        let old = store.authorize(baseURL: URL(string: "http://example.invalid/a/api/external")!, token: "a")
        let new = store.authorize(baseURL: URL(string: "http://example.invalid/b/api/external")!, token: "b")

        XCTAssertFalse(ActivityFeedbackBoundary.shouldUpdate(
            sessionId: old,
            sessionIDInActivity: old.uuidString,
            isSessionCurrent: store.isCurrent
        ), "旧会话被替换后不得反馈")
        XCTAssertTrue(ActivityFeedbackBoundary.shouldUpdate(
            sessionId: new,
            sessionIDInActivity: new.uuidString,
            isSessionCurrent: store.isCurrent
        ))
    }

    func testFeedbackBoundaryRevalidatesBetweenPerActivityUpdates() {
        let (_, id) = makeSession()
        var sessionCurrent = true
        var updated = 0
        // 模拟两个目标 Activity；第一次 update 的 await 期间会话失效。
        for _ in 0..<2 {
            if ActivityFeedbackBoundary.shouldUpdate(
                sessionId: id,
                sessionIDInActivity: id.uuidString,
                isSessionCurrent: { _ in sessionCurrent }
            ) {
                updated += 1
                sessionCurrent = false
            }
        }
        XCTAssertEqual(updated, 1, "每个目标更新前都必须重新校验当前授权")
    }
}
