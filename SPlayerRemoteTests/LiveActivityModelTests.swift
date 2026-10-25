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
}
