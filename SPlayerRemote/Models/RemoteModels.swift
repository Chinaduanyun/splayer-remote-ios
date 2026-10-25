import Foundation

/// 播放状态，对应上游 `GET /api/external/status` 的 `state` 字段。
/// 上游只保证 playing / buffering / paused；其它值容错为 `.unknown` 并按暂停处理。
enum PlaybackState: String, Equatable {
    case playing
    case buffering
    case paused
    case unknown

    init(rawState: String) {
        switch rawState.lowercased() {
        case "playing": self = .playing
        case "buffering": self = .buffering
        case "paused": self = .paused
        default: self = .unknown
        }
    }

    /// 面向中文 UI 的展示文本。
    var displayName: String {
        switch self {
        case .playing: return "播放中"
        case .buffering: return "缓冲中"
        case .paused: return "已暂停"
        case .unknown: return "未知"
        }
    }

    /// 是否处于“正在播放”语义（用于按钮状态切换）。
    var isPlaying: Bool { self == .playing }
}

/// `GET /api/external/info` 响应。
struct InfoResponse: Decodable, Equatable {
    var name: String
    var version: String
    var wsClients: Int

    init(name: String = "SPlayer Next", version: String = "unknown", wsClients: Int = 0) {
        self.name = name
        self.version = version
        self.wsClients = wsClients
    }

    private enum CodingKeys: String, CodingKey { case name, version, wsClients }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "SPlayer Next"
        version = (try? c.decode(String.self, forKey: .version)) ?? "unknown"
        wsClients = (try? c.decode(Int.self, forKey: .wsClients)) ?? 0
    }
}

/// `GET /api/external/status` 响应。position/duration 单位为毫秒，volume 为 0...1。
struct StatusResponse: Decodable, Equatable {
    var state: PlaybackState
    var position: Int
    var duration: Int
    var volume: Double
    var isFinished: Bool

    init(
        state: PlaybackState = .paused,
        position: Int = 0,
        duration: Int = 0,
        volume: Double = 1,
        isFinished: Bool = false
    ) {
        self.state = state
        self.position = position
        self.duration = duration
        self.volume = volume
        self.isFinished = isFinished
    }

    private enum CodingKeys: String, CodingKey {
        case state, position, duration, volume, isFinished
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decode(String.self, forKey: .state)) ?? ""
        state = PlaybackState(rawState: raw)
        position = (try? c.decode(Int.self, forKey: .position)) ?? 0
        duration = (try? c.decode(Int.self, forKey: .duration)) ?? 0
        volume = (try? c.decode(Double.self, forKey: .volume)) ?? 1
        isFinished = (try? c.decode(Bool.self, forKey: .isFinished)) ?? false
    }
}

/// `GET /api/external/now-playing` 响应。
///
/// ⚠️ 上游同时返回 `src`（媒体地址），本 App **刻意不解析** 该字段：
/// 它既不是可展示的元数据，也必须避免泄漏到 UI 或日志中。
struct NowPlayingResponse: Decodable, Equatable {
    var songId: Int
    var paused: Bool
    var playing: Bool
    var buffering: Bool
    var position: Int
    var duration: Int
    var volume: Double

    init(
        songId: Int = 0,
        paused: Bool = false,
        playing: Bool = false,
        buffering: Bool = false,
        position: Int = 0,
        duration: Int = 0,
        volume: Double = 1
    ) {
        self.songId = songId
        self.paused = paused
        self.playing = playing
        self.buffering = buffering
        self.position = position
        self.duration = duration
        self.volume = volume
    }

    private enum CodingKeys: String, CodingKey {
        case songId, paused, playing, buffering, position, duration, volume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        songId = (try? c.decode(Int.self, forKey: .songId)) ?? 0
        paused = (try? c.decode(Bool.self, forKey: .paused)) ?? false
        playing = (try? c.decode(Bool.self, forKey: .playing)) ?? false
        buffering = (try? c.decode(Bool.self, forKey: .buffering)) ?? false
        position = (try? c.decode(Int.self, forKey: .position)) ?? 0
        duration = (try? c.decode(Int.self, forKey: .duration)) ?? 0
        volume = (try? c.decode(Double.self, forKey: .volume)) ?? 1
    }
}

/// 支持的控制指令，rawValue 即上游 POST 路径片段（含 prev 的实际路径）。
enum RemoteCommand: String, CaseIterable {
    case play
    case pause
    case stop
    case next
    case prev

    var displayName: String {
        switch self {
        case .play: return "播放"
        case .pause: return "暂停"
        case .stop: return "停止"
        case .next: return "下一曲"
        case .prev: return "上一曲"
        }
    }

    var systemImage: String {
        switch self {
        case .play: return "play.fill"
        case .pause: return "pause.fill"
        case .stop: return "stop.fill"
        case .next: return "forward.fill"
        case .prev: return "backward.fill"
        }
    }
}
