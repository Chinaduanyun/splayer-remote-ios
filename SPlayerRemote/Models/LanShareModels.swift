import Foundation

/// 局域网分享（`/api/lanShare/getQueue`、`/api/lanShare/getLyric`）的容错解码模型。
///
/// 安全 / 稳健约定：
/// - 只描述展示所需字段；**绝不**包含媒体 `src` / 流地址 / 鉴权信息；
/// - 所有来自对端的文本与数量都做上限裁剪，避免超长或恶意负载撑爆 UI / 日志；
/// - 缺失字段一律容错为 `nil`，绝不用伪造默认值冒充真实元数据（UI 负责显示占位符）；
/// - 封面地址只接受 http / https，其它 scheme 一律丢弃。
enum LanShareLimits {
    static let title = 300
    static let artist = 200
    static let album = 200
    static let identifier = 128
    static let source = 40
    static let lyricLine = 500
    static let maxTracks = 2000
    static let maxLyricLines = 5000
    static let maxURLLength = 2048
    static let maxArtists = 8
    static let maxArtistLine = 240
    /// 局域网元数据响应体字节上限（流式读取，超限即停止）。
    static let maxQueueResponseBytes = 1_000_000
    static let maxLyricResponseBytes = 512_000
}

/// 对来自对端的原始值做类型容错与长度裁剪。
enum LanShareSanitizer {
    static func text(_ value: Any?, limit: Int) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }

    static func identifier(_ value: Any?) -> String? {
        if let raw = value as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(LanShareLimits.identifier))
        }
        if let number = value as? NSNumber {
            return String(number.stringValue.prefix(LanShareLimits.identifier))
        }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    /// 仅接受 http / https，且有主机名；拒绝 `file://`、`javascript:`、裸相对路径等。
    static func httpURL(_ value: Any?) -> URL? {
        guard let string = text(value, limit: LanShareLimits.maxURLLength),
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }
}

struct LanShareArtist: Equatable {
    let id: String?
    let name: String
}

struct LanShareAlbum: Equatable {
    let id: String?
    let name: String?
    let coverURL: URL?
}

/// 队列中的一首曲目。`title` 等可为 `nil`：上游未提供时 UI 必须显示占位符而非编造。
struct LanShareTrack: Equatable, Identifiable {
    let id: String
    let source: String?
    let title: String?
    let artists: [LanShareArtist]
    let album: LanShareAlbum?
    let durationMs: Int
    let coverURL: URL?

    /// 艺人行，例如 `A / B`；没有任何艺人时为 `nil`。
    /// 数量与聚合长度均有限制，避免异常数据撑爆 UI / Activity 载荷。
    var artistLine: String? {
        let names = artists.prefix(LanShareLimits.maxArtists).map(\.name).filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let joined = names.joined(separator: " / ")
        return String(joined.prefix(LanShareLimits.maxArtistLine))
    }

    /// 时长文本；未知 (>0 才有效) 时为 `nil`。
    var durationText: String? {
        guard durationMs > 0 else { return nil }
        let totalSeconds = durationMs / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    static func decode(_ raw: [String: Any]) -> LanShareTrack? {
        guard let id = LanShareSanitizer.identifier(raw["id"]) else { return nil }
        let artists: [LanShareArtist] = ((raw["artists"] as? [[String: Any]]) ?? [])
            .prefix(LanShareLimits.maxArtists)
            .compactMap { item in
                guard let name = LanShareSanitizer.text(item["name"], limit: LanShareLimits.artist) else { return nil }
                return LanShareArtist(id: LanShareSanitizer.identifier(item["id"]), name: name)
            }

        var album: LanShareAlbum?
        if let rawAlbum = raw["album"] as? [String: Any] {
            album = LanShareAlbum(
                id: LanShareSanitizer.identifier(rawAlbum["id"]),
                name: LanShareSanitizer.text(rawAlbum["name"], limit: LanShareLimits.album),
                coverURL: LanShareSanitizer.httpURL(rawAlbum["cover"])
            )
        }

        let trackCover = LanShareSanitizer.httpURL(raw["cover"])
        return LanShareTrack(
            id: id,
            source: LanShareSanitizer.text(raw["source"], limit: LanShareLimits.source),
            title: LanShareSanitizer.text(raw["title"], limit: LanShareLimits.title),
            artists: artists,
            album: album,
            durationMs: max(0, LanShareSanitizer.int(raw["duration"]) ?? 0),
            coverURL: trackCover ?? album?.coverURL
        )
    }
}

/// `getQueue` 的成功负载：`{playIndex, tracks:[...]}`。
struct LanShareQueue: Equatable {
    let revision: Int
    /// 上游提供的播放下标；可能过期，仅作参考，不作为权威匹配依据。
    let playIndex: Int?
    let tracks: [LanShareTrack]

    var trackCount: Int { tracks.count }

    func index(of track: LanShareTrack) -> Int? {
        tracks.firstIndex(of: track)
    }

    /// 按外部 `nowPlaying.songId` 匹配曲目，而不是依赖可能过期的 `playIndex`。
    /// 提供 `source` 时会优先匹配同源曲目；否则回退到首个同 id 曲目。
    func matchingTrack(songId: Int?, source: String? = nil) -> LanShareTrack? {
        guard let songId else { return nil }
        let idString = String(songId)
        let candidates = tracks.filter { $0.id == idString }
        if let source, let preferred = candidates.first(where: {
            $0.source?.caseInsensitiveCompare(source) == .orderedSame
        }) {
            return preferred
        }
        return candidates.first
    }

    /// 解析响应体：`{ok:false,...}` 或缺少 data 时返回 `nil`（未就绪）。
    static func decode(from data: Data) throws -> LanShareQueue? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw RemoteAPIError.decoding
        }
        guard (root["ok"] as? Bool) == true else { return nil }
        guard let payload = root["data"] as? [String: Any] else { return nil }
        let revision = LanShareSanitizer.int(root["revision"]) ?? 0
        let playIndex = LanShareSanitizer.int(payload["playIndex"])
        let rawTracks = (payload["tracks"] as? [[String: Any]]) ?? []
        let tracks = rawTracks
            .prefix(LanShareLimits.maxTracks)
            .compactMap(LanShareTrack.decode)
        return LanShareQueue(revision: revision, playIndex: playIndex, tracks: tracks)
    }
}

struct LanShareLyricSource: Equatable {
    let source: String?
    let format: String
    let platform: String?
}

struct LanShareLyricLine: Equatable, Identifiable {
    let id: Int
    let timeMs: Int
    let text: String
    let translation: String?
}

/// 解析后的歌词文档。`isSupported == false` 表示格式不受支持（例如非 LRC），UI 应优雅降级。
struct LanShareLyricDocument: Equatable {
    let revision: Int
    let source: LanShareLyricSource
    let lines: [LanShareLyricLine]
    let isSupported: Bool

    /// 当前播放位置对应的高亮行下标（最后一行时间 <= position），无匹配时为 `nil`。
    func lineIndex(forPositionMs positionMs: Int) -> Int? {
        guard !lines.isEmpty else { return nil }
        var result: Int?
        for (index, line) in lines.enumerated() {
            if line.timeMs <= positionMs { result = index } else { break }
        }
        return result
    }

    static func decode(from data: Data) throws -> LanShareLyricDocument? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw RemoteAPIError.decoding
        }
        guard (root["ok"] as? Bool) == true else { return nil }
        guard let payload = root["data"] as? [String: Any] else { return nil }
        let revision = LanShareSanitizer.int(root["revision"]) ?? 0

        let rawSource = payload["source"] as? [String: Any]
        let format = LanShareSanitizer.text(rawSource?["format"], limit: 20)?.lowercased() ?? "unknown"
        let source = LanShareLyricSource(
            source: LanShareSanitizer.text(rawSource?["source"], limit: LanShareLimits.source),
            format: format,
            platform: LanShareSanitizer.text(rawSource?["platform"], limit: LanShareLimits.source)
        )

        // 只支持 LRC；其它格式（含 TTML 等）如实判定为不支持，绝不臆测解析。
        guard format == "lrc" else {
            return LanShareLyricDocument(revision: revision, source: source, lines: [], isSupported: false)
        }

        let input = payload["input"] as? [String: Any]
        let maxChars = LanShareLimits.maxLyricLines * LanShareLimits.lyricLine
        let content = LanShareSanitizer.text(input?["content"], limit: maxChars) ?? ""
        let translation = LanShareSanitizer.text(input?["translation"], limit: maxChars) ?? ""
        let lines = LRCParser.parse(content: content, translation: translation)
        return LanShareLyricDocument(revision: revision, source: source, lines: lines, isSupported: true)
    }
}

/// 极简 LRC 解析：支持一行多时间戳、`[mm:ss]` 与 `[mm:ss.xx/xxx]`，按时间排序并限制行数。
enum LRCParser {
    private static let tagPattern = try? NSRegularExpression(
        pattern: #"\[(\d{1,4}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
    )

    static func parse(content: String, translation: String) -> [LanShareLyricLine] {
        let primary = timedLines(from: content, limit: LanShareLimits.maxLyricLines)
        guard !primary.isEmpty else { return [] }
        let translated = Dictionary(
            timedLines(from: translation, limit: LanShareLimits.maxLyricLines).map { ($0.timeMs, $0.text) },
            uniquingKeysWith: { first, _ in first }
        )

        return primary
            .prefix(LanShareLimits.maxLyricLines)
            .enumerated()
            .map { index, entry in
                LanShareLyricLine(
                    id: index,
                    timeMs: entry.timeMs,
                    text: entry.text,
                    translation: translated[entry.timeMs]
                )
            }
    }

    private static func timedLines(from text: String, limit: Int) -> [(timeMs: Int, text: String)] {
        guard !text.isEmpty, let regex = tagPattern else { return [] }
        var result: [(Int, String)] = []
        scan: for rawLine in text.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = regex.matches(in: rawLine, range: range)
            guard !matches.isEmpty else { continue }
            // 标签之后的文本即歌词内容。
            guard let last = matches.last, let contentRange = Range(last.range, in: rawLine) else { continue }
            let rawContent = String(rawLine[contentRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawContent.isEmpty else { continue }
            let content = String(rawContent.prefix(LanShareLimits.lyricLine))
            for match in matches {
                // 提前封顶：异常超多时间戳不会先构建完整数组再排序。
                guard result.count < limit else { break scan }
                guard let time = timeMs(from: match, in: rawLine) else { continue }
                result.append((time, content))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    private static func timeMs(from match: NSTextCheckingResult, in line: String) -> Int? {
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return String(line[range])
        }
        guard let minutesText = group(1), let minutes = Int(minutesText) else { return nil }
        // 第 3 组（毫秒）缺失时 `group` 返回 nil。
        guard let secondsText = group(2), let seconds = Int(secondsText) else { return nil }
        let fractionText = group(3) ?? ""
        var milliseconds = 0
        if !fractionText.isEmpty {
            let digits = fractionText.prefix(3)
            let value = Int(digits) ?? 0
            switch digits.count {
            case 1: milliseconds = value * 100
            case 2: milliseconds = value * 10
            default: milliseconds = value
            }
        }
        return minutes * 60_000 + seconds * 1000 + milliseconds
    }
}
