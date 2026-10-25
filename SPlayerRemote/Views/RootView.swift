import SwiftUI

/// 主界面：单一「正在播放」面板 + 悬浮玻璃交通控制簇。
struct RootView: View {
    @EnvironmentObject private var remote: RemoteViewModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettings = false
    @State private var showDiagnostics = false

    var body: some View {
        ZStack {
            WarmBackground()

            ScrollView {
                VStack(spacing: 22) {
                    header

                    if remote.connection.isConnected {
                        PlaybackStatusPanel()
                        TransportCluster()
                    } else {
                        EmptyStatePanel(onOpenSettings: { showSettings = true })
                    }

                    if let error = remote.lastError {
                        ErrorBanner(message: error)
                    }

                    footer
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable { await remote.refreshNow() }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
        }
        .onChange(of: scenePhase) { _, phase in
            let active = phase == .active
            remote.setSceneActive(active)
            if active, !showSettings {
                Task { await remote.connectIfConfigured() }
            }
        }
        .task {
            // 启动时仅在用户显式开启自动连接且有可用配置时连接。
            if !showSettings {
                await remote.connectIfConfigured()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: remote.connection)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SPlayer 遥控器")
                    .font(.title2.bold())
                Text("适用于 SPlayer for Android Next")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ConnectionBadge(
                state: remote.connection,
                isStale: remote.isStale,
                transport: remote.transport
            )

            Button {
                showDiagnostics = true
            } label: {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("诊断")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if case .connected = remote.connection {
                Button {
                    remote.disconnectByUser()
                } label: {
                    Label("断开连接", systemImage: "wifi.slash")
                        .font(.footnote)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Text("非官方应用，与 SPlayer 项目无隶属关系。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// 未连接时的引导面板。设置入口由父视图统一持有，保证自动连接抑制对两个入口一致生效。
private struct EmptyStatePanel: View {
    @EnvironmentObject private var remote: RemoteViewModel
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)

            Text("尚未连接")
                .font(.title3.bold())

            if case .failed(let message) = remote.connection {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("在 Android 端开启「设置 → 外部 API」并允许局域网访问，然后在设置中填写主机、端口与 Token。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                GlassTransportButton(systemImage: "gearshape", label: "打开设置", prominent: true) {
                    onOpenSettings()
                }
                Button {
                    Task { await remote.connect() }
                } label: {
                    Text("连接")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 88, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(remote.connection == .connecting)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .glassPanel()
    }
}

/// 错误提示条。
private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
