import SwiftUI

/// 设置面板：主机、端口、Token、测试连接，以及安全说明。
///
/// 字段使用**本地草稿**，只有「保存并连接」成功写入钥匙串后才提交到已保存配置。
/// 这样编辑中的 host / Token 不会泄漏给后台重连或自动连接。
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var remote: RemoteViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var hostDraft = ""
    @State private var portDraft = ""
    @State private var tokenDraft = ""
    @State private var useWebSocketDraft = true
    @State private var autoConnectDraft = false
    @State private var liveActivityDraft = false
    @State private var didLoadDrafts = false

    @State private var validationMessage: String?
    @State private var isWorking = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("主机名或 IP", text: $hostDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel("主机")
                    TextField("端口", text: $portDraft)
                        .keyboardType(.numberPad)
                        .accessibilityLabel("端口")
                } header: {
                    Text("主机与端口")
                } footer: {
                    Text("示例：192.168.31.100、myphone.local 或 [fe80::1]。默认端口 \(HostValidator.defaultPort)。")
                }

                Section {
                    Toggle("实时状态（WebSocket）", isOn: $useWebSocketDraft)
                    Toggle("启动时自动连接", isOn: $autoConnectDraft)
                    Toggle("锁屏 / 灵动岛实时活动", isOn: $liveActivityDraft)
                        .onChange(of: liveActivityDraft) { _, enabled in
                            remote.setLiveActivityEnabled(enabled)
                        }
                } header: {
                    Text("连接偏好")
                } footer: {
                    Text("启用后会尝试建立只读实时通道；不可用时自动回退到 HTTP 轮询，不影响控制。自动连接仅在已保存有效主机与令牌时生效。实时活动需系统允许，且仅在 App 已连接时提供上一曲 / 播放暂停 / 下一曲。")
                }

                Section {
                    SecureField("访问令牌", text: $tokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("访问令牌")
                        .accessibilityHint("Token 仅保存在本机钥匙串")
                    Button(role: .destructive) {
                        clearToken()
                    } label: {
                        Label("清除已保存的令牌", systemImage: "trash")
                    }
                } header: {
                    Text("访问令牌")
                } footer: {
                    Text("Token 保存在系统钥匙串中，不会写入明文文件或日志。")
                }

                if let keychainError = settings.keychainError {
                    Section {
                        Text(keychainError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await saveAndConnect() }
                    } label: {
                        HStack {
                            if isWorking { ProgressView().controlSize(.small) }
                            Text(isWorking ? "连接中…" : "保存并连接")
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(isWorking)
                }

                Section {
                    Label("Token 通过明文 HTTP 传输，请仅在可信的家庭 / 受信任 Wi-Fi 中使用。", systemImage: "lock.open")
                        .font(.footnote)
                    Label("请勿在公网或不可信网络上暴露该端口。", systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                    Label("外部 API 默认关闭；需要在 Android 端「设置 → 外部 API」手动开启并允许局域网访问。", systemImage: "slider.horizontal.3")
                        .font(.footnote)
                } header: {
                    Text("安全说明")
                }

                Section {
                    Label("协作点播使用经过批准的查询串 token（仅存在于内存中），绝不记录到日志。", systemImage: "key.horizontal")
                        .font(.footnote)
                    Label("队列点播只影响主机**当前队列**；不提供歌单 / 收藏 / 搜索等未验证接口。", systemImage: "list.bullet.rectangle")
                        .font(.footnote)
                    Label("发送后只等待权威播放状态确认，不会重复发送命令。", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                    Button {
                        remote.retryCollaborationAuthorization()
                    } label: {
                        Label("重试协作授权", systemImage: "arrow.clockwise")
                            .frame(minHeight: 44)
                    }
                    .disabled(!remote.connection.isConnected)
                } header: {
                    Text("协作控制（当前队列）")
                }

                Section {
                    Label("在系统设置 → 通知 中允许本 App 的通知与实时活动。", systemImage: "bell.badge")
                        .font(.footnote)
                    Label("灵动岛仅在支持灵动岛的 iPhone 机型上显示；其它机型只会看到锁屏实时活动。", systemImage: "iphone.gen3")
                        .font(.footnote)
                    Label("若看不到灵动岛：长按灵动岛 / 锁屏活动可展开详情；必要时删除 App 后重装以刷新内嵌的实时活动扩展。", systemImage: "arrow.clockwise.circle")
                        .font(.footnote)
                    Label("实时活动依赖系统调度，不保证持续后台联网；离开 App 后状态可能延迟。", systemImage: "clock.arrow.circlepath")
                        .font(.footnote)
                } header: {
                    Text("灵动岛 / 实时活动支持")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("v\(Self.appVersion)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("版本 \(Self.appVersion)")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Image(systemName: "waveform.path.ecg")
                    }
                    .accessibilityLabel("诊断")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView()
            }
            .onAppear(perform: loadDraftsIfNeeded)
        }
    }

    private func loadDraftsIfNeeded() {
        guard !didLoadDrafts else { return }
        didLoadDrafts = true
        hostDraft = settings.host
        portDraft = settings.portText
        tokenDraft = settings.token
        useWebSocketDraft = settings.useWebSocket
        autoConnectDraft = settings.autoConnect
        liveActivityDraft = settings.liveActivityEnabled
    }

    private func saveAndConnect() async {
        validationMessage = nil
        isWorking = true
        defer { isWorking = false }

        // 原子提交：先写钥匙串，成功后再更新已保存配置。失败不改变任何已保存值。
        do {
            try settings.saveConfiguration(
                host: hostDraft,
                portText: portDraft,
                token: tokenDraft,
                useWebSocket: useWebSocketDraft,
                autoConnect: autoConnectDraft
            )
        } catch {
            validationMessage = remote.message(for: error)
            return
        }

        await remote.connect()
        if case .failed(let message) = remote.connection {
            validationMessage = message
        }
    }

    private func clearToken() {
        do {
            try settings.clearToken()
            tokenDraft = ""
            validationMessage = nil
        } catch {
            validationMessage = remote.message(for: error)
        }
    }

    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
