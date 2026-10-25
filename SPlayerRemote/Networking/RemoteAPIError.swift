import Foundation

/// 远端 API 调用产生的错误，附带面向用户的中文说明。
enum RemoteAPIError: Error, Equatable, LocalizedError {
    /// 本地配置非法（host/port），请求根本不会发出。
    case invalidConfiguration(String)
    /// 尚未连接或连接已失效。
    case notConnected
    /// 401：Token 缺失 / 无效。
    case unauthorized
    /// 403：服务端拒绝（未开启外部 API、未允许局域网访问等）。
    case forbidden
    /// 其它非 2xx 状态码。
    case httpStatus(Int)
    /// JSON 解析失败。
    case decoding
    /// 网络层错误（超时、连接被拒绝等）。
    case transport(String)
    /// 请求被取消。
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            return reason
        case .notConnected:
            return "尚未连接，请先在设置中填写主机并连接。"
        case .unauthorized:
            return "鉴权失败（401）：Token 无效或已过期，请在设置中重新填写。"
        case .forbidden:
            return "服务器拒绝访问（403）：请确认已在 Android 端「设置 → 外部 API」开启服务，并允许局域网访问。"
        case .httpStatus(let code):
            return "服务器返回异常状态码：\(code)。"
        case .decoding:
            return "响应格式无法解析：可能不是 SPlayer 外部 API 服务。"
        case .transport(let detail):
            return "网络请求失败：\(detail)"
        case .cancelled:
            return "请求已取消。"
        }
    }
}
