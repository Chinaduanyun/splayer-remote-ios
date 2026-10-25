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
    @State private var didLoadDrafts = false

    @State private var validationMessage: String?
    @State private var isWorking = false

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
                } header: {
                    Text("连接偏好")
                } footer: {
                    Text("启用后会尝试建立只读实时通道；不可用时自动回退到 HTTP 轮询，不影响控制。自动连接仅在已保存有效主机与令牌时生效。")
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
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
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
}
