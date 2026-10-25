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
                    Text("SPlayer 外部 API 仅返回歌曲 ID、进度、音量等状态，不提供标题、艺人或封面，因此本 App 不会虚构这些信息，也不显示媒体地址或原始响应。")
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
