import SwiftUI

/// 诊断面板：只读展示连接 / 传输 / 播放状态与最近更新时间。
///
/// 安全约束：
/// - 绝不显示 Token、`src`、原始 JSON 或任何 URL；
/// - 上游不提供标题 / 艺人 / 封面，这里如实说明，不伪造元数据。
struct DiagnosticsView: View {
    @EnvironmentObject private var remote: RemoteViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("应用") {
                    DiagnosticsRow(label: "名称", value: Self.appName)
                    DiagnosticsRow(label: "版本", value: Self.appVersion)
                }

                Section("连接") {
                    DiagnosticsRow(label: "REST", value: restText)
                    DiagnosticsRow(label: "传输通道", value: remote.transport.displayName)
                    if let clients = remote.wsClientCount {
                        DiagnosticsRow(label: "WS 客户端数", value: "\(clients)")
                    }
                    DiagnosticsRow(label: "最近成功更新", value: lastUpdateText(remote.lastSuccessfulUpdate))
                    DiagnosticsRow(label: "最近 REST 成功", value: lastUpdateText(remote.lastSuccessfulRestUpdate))
                    DiagnosticsRow(label: "歌曲标识", value: remote.songId.map { "#\($0)" } ?? "—")
                }

                Section("元数据（局域网分享，只读）") {
                    DiagnosticsRow(label: "状态", value: metadataStateText)
                    DiagnosticsRow(label: "队列曲目数", value: remote.queue.map { "\($0.trackCount)" } ?? "—")
                    DiagnosticsRow(label: "队列版本", value: remote.queue.map { "\($0.revision)" } ?? "—")
                    DiagnosticsRow(label: "当前曲目", value: remote.currentTrack?.title ?? "—")
                    DiagnosticsRow(label: "艺人", value: remote.currentTrack?.artistLine ?? "—")
                    DiagnosticsRow(label: "歌词", value: lyricText)
                    if let error = remote.metadataError {
                        DiagnosticsRow(label: "最近错误", value: error)
                    }
                }

                Section("协作控制（当前队列）") {
                    DiagnosticsRow(label: "主机分享", value: remote.collaborationStatus?.enabled == true ? "已开启" : "未开启")
                    DiagnosticsRow(label: "协作开关", value: remote.collaborationStatus?.collabEnabled == true ? "已开启" : "未开启")
                    DiagnosticsRow(label: "本机授权", value: remote.collaborationStatus?.collabAuthorized == true ? "已授权" : "未授权")
                    DiagnosticsRow(label: "通道", value: remote.collaborationState.displayName)
                    DiagnosticsRow(label: "可点播", value: remote.canSelectFromQueue ? "是" : "否")
                    if let pending = remote.pendingPlayback {
                        DiagnosticsRow(label: "待确认曲目", value: "#\(pending.trackId)（下标 \(pending.index)）")
                    }
                    // 不展示 wsToken / URL / 原始错误，避免泄漏内存级凭据。
                }

                Section("播放（只读）") {
                    DiagnosticsRow(label: "状态", value: remote.playbackState.displayName)
                    DiagnosticsRow(label: "缓冲", value: (remote.isBuffering) ? "是" : "否")
                    DiagnosticsRow(label: "播放倍速", value: rateText)
                    if let ready = remote.isReady {
                        DiagnosticsRow(label: "就绪", value: ready ? "是" : "否")
                    }
                    if let code = remote.remoteErrorCode {
                        DiagnosticsRow(label: "远端错误码", value: "\(code)")
                    }
                }

                Section {
                    Text("元数据（标题 / 艺人 / 专辑 / 封面 / 队列 / 歌词）来自 SPlayer 的局域网分享接口，仅在开启分享时可用；不可用时 App 只显示歌曲标识，绝不伪造。封面图片使用独立、无凭据的网络会话下载，不会携带令牌或 Cookie。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("操作") {
                    Button {
                        Task { await remote.refreshNow() }
                    } label: {
                        Label("手动刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(!remote.connection.isConnected)

                    if remote.connection.isConnected {
                        Button(role: .destructive) {
                            remote.disconnectByUser()
                        } label: {
                            Label("断开连接", systemImage: "wifi.slash")
                        }
                    } else {
                        Button {
                            Task { await remote.connect() }
                        } label: {
                            Label("重新连接", systemImage: "arrow.clockwise.circle")
                        }
                        .disabled(remote.connection == .connecting)
                    }
                }

                if let error = remote.lastError {
                    Section("最近错误") {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var restText: String {
        if !remote.connection.isConnected { return "未连接" }
        return remote.restAvailable ? "可用" : "已连接（REST 数据过期）"
    }

    private func lastUpdateText(_ date: Date?) -> String {
        guard let date else { return "尚无" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private var rateText: String {
        let rate = remote.playbackRate
        guard rate.isFinite else { return "—" }
        return String(format: "%.2fx", rate)
    }

    private var metadataStateText: String {
        switch remote.metadataState {
        case .idle: return "尚未获取"
        case .loading: return "获取中"
        case .available: return "可用"
        case .unavailable: return "不可用"
        }
    }

    private var lyricText: String {
        guard let lyric = remote.lyric else { return "—" }
        if !lyric.isSupported { return "格式不支持（\(lyric.source.format)）" }
        return lyric.lines.isEmpty ? "暂无" : "\(lyric.lines.count) 行"
    }

    // MARK: - Bundle 信息（带兜底）

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "SPlayer 遥控器"
    }

    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

private struct DiagnosticsRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
