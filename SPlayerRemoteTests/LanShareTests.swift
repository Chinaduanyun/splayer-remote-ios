import XCTest
@testable import SPlayerRemote

/// 局域网分享元数据解码 / 匹配 / 容错（仅使用合成夹具，不含真实用户数据）。
final class LanShareTests: XCTestCase {

    // MARK: - 队列解码

    func testDecodesQueueWithSyntheticFixture() throws {
        let queue = try XCTUnwrap(LanShareQueue.decode(from: LanShareFixtures.queueJSON))
        XCTAssertEqual(queue.revision, 11)
        XCTAssertEqual(queue.playIndex, 0)
        XCTAssertEqual(queue.trackCount, 3)

        let first = try XCTUnwrap(queue.tracks.first)
        XCTAssertEqual(first.id, "19827042")
        XCTAssertEqual(first.source, "netease")
        XCTAssertEqual(first.title, "Example song one")
        XCTAssertEqual(first.artistLine, "Example artist")
        XCTAssertEqual(first.album?.name, "Example album")
        XCTAssertEqual(first.durationMs, 213266)
        XCTAssertEqual(first.coverURL?.scheme, "https")
        XCTAssertEqual(first.durationText, "3:33")
    }

    func testNotReadyQueueReturnsNil() throws {
        XCTAssertNil(try LanShareQueue.decode(from: LanShareFixtures.queueNotReady))
    }

    func testMalformedQueueThrows() {
        XCTAssertThrowsError(try LanShareQueue.decode(from: Data("not json".utf8)))
    }

    // MARK: - 匹配：按 songId 而非 playIndex

    func testMatchesBySongIdNotStalePlayIndex() {
        let payload: [String: Any] = [
            "ok": true,
            "revision": 2,
            "data": [
                "playIndex": 0,
                "tracks": [
                    LanShareFixtures.track(id: "999", title: "Stale playIndex target"),
                    LanShareFixtures.track(id: "42", title: "Real current"),
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let queue = try! XCTUnwrap(LanShareQueue.decode(from: data))

        // playIndex 指向 999，但权威 songId=42 必须命中 42。
        XCTAssertEqual(queue.matchingTrack(songId: 42)?.id, "42")
        XCTAssertEqual(queue.matchingTrack(songId: 42)?.title, "Real current")
    }

    func testMatchFallsBackWhenSourceProvidedPreferentially() {
        let payload: [String: Any] = [
            "ok": true,
            "revision": 2,
            "data": [
                "playIndex": 0,
                "tracks": [
                    LanShareFixtures.track(id: "42", source: "netease", title: "From netease"),
                    LanShareFixtures.track(id: "42", source: "local", title: "From local"),
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let queue = try! XCTUnwrap(LanShareQueue.decode(from: data))
        XCTAssertEqual(queue.matchingTrack(songId: 42, source: "local")?.title, "From local")
        XCTAssertEqual(queue.matchingTrack(songId: 42, source: "netease")?.title, "From netease")
    }

    func testMatchReturnsNilWhenSongMissing() {
        let queue = LanShareFixtures.queue
        XCTAssertNil(queue.matchingTrack(songId: 12_345))
        XCTAssertNil(queue.matchingTrack(songId: nil))
    }

    // MARK: - 容错 / 长度裁剪 / 封面 URL 安全

    func testTolerantDecodingWithoutFakeDefaults() throws {
        let payload: [String: Any] = [
            "ok": true,
            "revision": 1,
            "data": ["tracks": [["id": "7"]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let queue = try XCTUnwrap(LanShareQueue.decode(from: data))
        let track = try XCTUnwrap(queue.tracks.first)
        XCTAssertEqual(track.id, "7")
        XCTAssertNil(track.title, "缺失标题必须为 nil，不得伪造")
        XCTAssertNil(track.artistLine)
        XCTAssertNil(track.album)
        XCTAssertNil(track.coverURL)
        XCTAssertEqual(track.durationMs, 0)
    }

    func testTrackWithoutIdIsDropped() throws {
        let payload: [String: Any] = [
            "ok": true,
            "revision": 1,
            "data": ["tracks": [["title": "no id"], LanShareFixtures.track(id: "9")]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let queue = try XCTUnwrap(LanShareQueue.decode(from: data))
        XCTAssertEqual(queue.tracks.map(\.id), ["9"])
    }

    func testLongTextIsTruncated() throws {
        let long = String(repeating: "a", count: 5_000)
        let payload: [String: Any] = [
            "ok": true,
            "revision": 1,
            "data": ["tracks": [["id": "1", "title": long]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let track = try XCTUnwrap(try LanShareQueue.decode(from: data)?.tracks.first)
        XCTAssertEqual(track.title?.count, LanShareLimits.title)
    }

    func testCoverURLRejectsNonHTTP() {
        XCTAssertNil(LanShareSanitizer.httpURL("file:///private/etc/passwd"))
        XCTAssertNil(LanShareSanitizer.httpURL("javascript:alert(1)"))
        XCTAssertNil(LanShareSanitizer.httpURL("/relative/cover.jpg"))
        XCTAssertNil(LanShareSanitizer.httpURL("ftp://example.invalid/x.jpg"))
        XCTAssertEqual(LanShareSanitizer.httpURL("http://example.invalid/x.jpg")?.scheme, "http")
        XCTAssertEqual(LanShareSanitizer.httpURL("https://example.invalid/x.jpg")?.scheme, "https")
    }

    // MARK: - 歌词

    func testDecodesLRCWithTranslationAndHighlight() throws {
        let lyric = try XCTUnwrap(LanShareLyricDocument.decode(from: LanShareFixtures.lyricJSON))
        XCTAssertTrue(lyric.isSupported)
        XCTAssertEqual(lyric.revision, 28)
        XCTAssertEqual(lyric.source.format, "lrc")
        XCTAssertEqual(lyric.lines.count, 3)
        XCTAssertEqual(lyric.lines[0].timeMs, 1_000)
        XCTAssertEqual(lyric.lines[0].text, "First line")
        XCTAssertEqual(lyric.lines[0].translation, "第一行")
        XCTAssertEqual(lyric.lines[2].translation, nil)
        XCTAssertEqual(lyric.lineIndex(forPositionMs: 0), nil)
        XCTAssertEqual(lyric.lineIndex(forPositionMs: 1_500), 0)
        XCTAssertEqual(lyric.lineIndex(forPositionMs: 6_000), 1)
    }

    func testUnsupportedLyricFormatDegradesGracefully() throws {
        let lyric = try XCTUnwrap(LanShareLyricDocument.decode(from: LanShareFixtures.unsupportedLyricJSON))
        XCTAssertFalse(lyric.isSupported)
        XCTAssertTrue(lyric.lines.isEmpty)
        XCTAssertEqual(lyric.source.format, "ttml")
    }

    func testNotReadyLyricReturnsNil() throws {
        XCTAssertNil(try LanShareLyricDocument.decode(from: Data(#"{"ok":false}"#.utf8)))
    }
}
