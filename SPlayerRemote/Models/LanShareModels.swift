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
    /// `/api/lanShare/getStatus` 响应体很小；超过即可疑。
    static let maxStatusResponseBytes = 64_000
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
    /// 上游队列中的**原始下标**（0 基）。解码时可能丢弃无 id 的行，
    /// 因此展示数组下标可能不等于主机下标；点播必须使用本字段。`nil` 表示不可选。
    var upstreamIndex: Int? = nil

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

    static func decode(_ raw: [String: Any], upstreamIndex: Int? = nil) -> LanShareTrack? {
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
            coverURL: trackCover ?? album?.coverURL,
            upstreamIndex: upstreamIndex
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
        // 保留下游**原始下标**：无 id 的行会被丢弃，展示下标不能直接当作主机下标发送。
        let tracks = rawTracks
            .prefix(LanShareLimits.maxTracks)
            .enumerated()
            .compactMap { index, raw in LanShareTrack.decode(raw, upstreamIndex: index) }
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

/// `/api/lanShare/getStatus` 的只读结果。
///
/// ⚠️ `wsToken` 只在**当前设备被主机授权**时返回；它仅用于建立协作控制 WS 的查询参数，
/// 属于内存级凭据：绝不持久化、绝不写入日志 / Activity 内容 / 错误文案。
/// `collabAuthorized` 由主机端根据设备 IP 判定；本 App 绝不自造授权，也不借用电脑的授权。
struct LanShareStatus: Equatable {
    let enabled: Bool
    let collabEnabled: Bool
    let collabAuthorized: Bool
    let wsToken: String?

    /// 是否具备建立协作通道的全部条件：开启分享 + 开启协作 + 已授权 + 有非空 wsToken。
    var canCollaborate: Bool {
        enabled && collabEnabled && collabAuthorized && !(wsToken ?? "").isEmpty
    }

    /// 容错解析：缺失字段一律视为 false / nil，绝不用默认值冒充授权。
    static func decode(from data: Data) throws -> LanShareStatus {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw RemoteAPIError.decoding
        }
        return LanShareStatus(
            enabled: (root["enabled"] as? Bool) ?? false,
            collabEnabled: (root["collabEnabled"] as? Bool) ?? false,
            collabAuthorized: (root["collabAuthorized"] as? Bool) ?? false,
            wsToken: LanShareSanitizer.text(root["wsToken"], limit: LanShareLimits.identifier)
        )
    }
}

/// 一次队列点播的**待确认**状态。
///
/// 服务端没有可靠 ack：`send` 完成只代表传输层已投递，绝不代表已播放。
/// 本 App 只在之后通过权威 `/api/external/now-playing` 的 songId 校验结果，
/// 绝不重复发送命令、绝不在断线重连后重放。
struct CollaborationPendingPlayback: Equatable {
    let trackId: String
    let index: Int
    let revision: Int
    let sentAt: Date
}

/// 队列行的一次**不可变点播选择**。
///
/// 由 UI 在渲染行时捕获，点播前必须与当前连接 / 队列逐项比对；
/// 特别是 `upstreamIndex` 必须是主机原始下标，不能使用可能被丢弃行压缩过的展示下标。
struct QueueSelectionIdentity: Equatable {
    let trackId: String
    let source: String?
    let upstreamIndex: Int
    let revision: Int
    let queueGeneration: Int
    let connectionGeneration: Int
}

/// 协作控制 WS 上送的命令信封。
/// 当前只使用 `playAt`（0 基下标）；其余动作不在本 App 暴露，保持“有限的当前队列”语义。
enum CollaborationCommand {
    /// 编码 `{type:"command",action:"playAt",value:<zeroBasedIndex>,ts:<milliseconds>}`。
    /// 非法下标（负数 / 非有限）返回 nil，调用方必须拒绝。
    static func playAt(index: Int, timestampMs: Int) -> Data? {
        guard index >= 0, timestampMs >= 0 else { return nil }
        let payload: [String: Any] = [
            "type": "command",
            "action": "playAt",
            "value": index,
            "ts": timestampMs,
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
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
