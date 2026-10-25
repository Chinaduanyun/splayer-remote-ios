import Foundation

/// 一条来自外部 API WebSocket 的消息。
///
/// 上游只会发送 `hello` / `event` / `ack` / `error` 四类信封；
/// 未知 `kind`、未知事件类型或无法解析的负载都必须被安全忽略（`.unknown`），
/// 绝不能因此中断连接、抛错或写入 UI 状态。
///
/// ⚠️ `stateChanged.data` 中的 `src` 是媒体地址，本 App **刻意不解析**：
/// 它既不是可展示的元数据，也必须避免泄漏到 UI 或日志中。
enum RemoteSocketMessage: Equatable {
    /// 握手问候：`{"kind":"hello","clients":1}`，`clients` 可缺失。
    case hello(clients: Int?)
    /// 状态变化：`{"kind":"event","type":"stateChanged","data":{...}}`。
    case stateChanged(StateChangedPayload)
    /// 播放结束：`{"kind":"event","type":"ended"}`，没有 `data`。
    case ended
    /// 控制确认：`{"kind":"ack","op":"play"}`（本 App 的 WS 为只读，通常不会收到）。
    case ack(op: String)
    /// 错误信封：`{"kind":"error","op":"play","error":"..."}`。
    case error(op: String, message: String)
    /// 未知 / 无法解析：安全忽略。
    case unknown

    static func decode(from text: String) -> RemoteSocketMessage {
        guard let data = text.data(using: .utf8) else { return .unknown }
        return decode(from: data)
    }

    /// 容错解析：任何结构不符都返回 `.unknown`，不抛错。
    static func decode(from data: Data) -> RemoteSocketMessage {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let kind = root["kind"] as? String
        else { return .unknown }

        switch kind {
        case "hello":
            return .hello(clients: (root["clients"] as? NSNumber)?.intValue)
        case "ack":
            guard let op = root["op"] as? String else { return .unknown }
            return .ack(op: op)
        case "error":
            guard let op = root["op"] as? String else { return .unknown }
            return .error(op: op, message: (root["error"] as? String) ?? "")
        case "event":
            guard let type = root["type"] as? String else { return .unknown }
            switch type {
            case "stateChanged":
                guard let data = root["data"] as? [String: Any] else { return .unknown }
                return .stateChanged(StateChangedPayload(dictionary: data))
            case "ended":
                return .ended
            default:
                return .unknown
            }
        default:
            return .unknown
        }
    }
}

/// `stateChanged` 事件负载的容错镜像。
///
/// 所有字段都是可选的：上游可能只推送发生变化的字段，缺失字段不得覆盖已有状态。
/// `src` 有意不在此模型中，从类型层面阻止它进入 UI / 日志。
struct StateChangedPayload: Equatable {
    var songId: Int?
    var paused: Bool?
    var ready: Bool?
    var playing: Bool?
    var buffering: Bool?
    var durationMs: Int?
    var positionMs: Int?
    var volume: Double?
    var playbackRate: Double?
    var errorCode: Int?

    init(
        songId: Int? = nil,
        paused: Bool? = nil,
        ready: Bool? = nil,
        playing: Bool? = nil,
        buffering: Bool? = nil,
        durationMs: Int? = nil,
        positionMs: Int? = nil,
        volume: Double? = nil,
        playbackRate: Double? = nil,
        errorCode: Int? = nil
    ) {
        self.songId = songId
        self.paused = paused
        self.ready = ready
        self.playing = playing
        self.buffering = buffering
        self.durationMs = durationMs
        self.positionMs = positionMs
        self.volume = volume
        self.playbackRate = playbackRate
        self.errorCode = errorCode
    }

    /// 从 `JSONSerialization` 字典容错读取；忽略 `src`。
    init(dictionary: [String: Any]) {
        self.init(
            songId: (dictionary["songId"] as? NSNumber)?.intValue,
            paused: dictionary["paused"] as? Bool,
            ready: dictionary["ready"] as? Bool,
            playing: dictionary["playing"] as? Bool,
            buffering: dictionary["buffering"] as? Bool,
            durationMs: (dictionary["durationMs"] as? NSNumber)?.intValue,
            positionMs: (dictionary["positionMs"] as? NSNumber)?.intValue,
            volume: (dictionary["volume"] as? NSNumber)?.doubleValue,
            playbackRate: (dictionary["playbackRate"] as? NSNumber)?.doubleValue,
            errorCode: (dictionary["errorCode"] as? NSNumber)?.intValue
        )
    }

    /// 是否携带可验证的播放状态（而非仅音量或空负载）。
    ///
    /// 只有携带这类字段的事件才能认定为「新鲜状态快照」，从而清除过期标记；
    /// 空负载 / 仅 `src` / 仅音量的负载不得影响 REST 可用性或控制门控。
    var isStatusBearing: Bool {
        playing != nil || buffering != nil || paused != nil
            || positionMs != nil || durationMs != nil || ready != nil
    }
}
