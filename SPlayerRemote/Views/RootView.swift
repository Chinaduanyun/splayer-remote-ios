import SwiftUI

/// 主界面：克制的「正在播放」面板 + 悬浮队列 / 歌词胶囊。
///
/// v1.3 版式重排：移除重复的元数据解释与巨大状态标题；版本 / 诊断移入设置工具栏；
/// 顶部只保留一条纤细的连接状态栏；底部胶囊放在安全区内，不遮挡控制。
struct RootView: View {
    @EnvironmentObject private var remote: RemoteViewModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettings = false
    @State private var tab = 0
    @State private var showLyric = false

    var body: some View {
        ZStack {
            WarmBackground()

            VStack(spacing: 0) {
                slimHeader.padding(.horizontal, 18)
                TabView(selection: $tab) {
                    DiscoveryView().tabItem { Label("发现", systemImage: "sparkles") }.tag(0)
                    nowPlayingPage.tabItem { Label("正在播放", systemImage: "play.circle") }.tag(1)
                    QueueSheet(embedded: true).tabItem { Label("当前队列", systemImage: "music.note.list") }.tag(2)
                }
                if tab != 1, remote.connection.isConnected {
                    HStack {
                        Button { tab = 1 } label: {
                            Text(remote.currentTrack?.title ?? "正在播放").lineLimit(1)
                        }
                        Spacer()
                        Button { remote.send(remote.nowPlaying?.playing == true ? .pause : .play) } label: { Image(systemName: remote.nowPlaying?.playing == true ? "pause.fill" : "play.fill") }
                            .disabled(!remote.canControl)
                    }.padding().background(.ultraThinMaterial)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showLyric) { LyricSheet() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                remote.setScenePhase(.active)
                if !showSettings { Task { await remote.connectIfConfigured() } }
            case .inactive: remote.setScenePhase(.inactive)
            default: remote.setScenePhase(.background)
            }
        }
        .task { if !showSettings { await remote.connectIfConfigured() } }
    }

    private var nowPlayingPage: some View {
            ScrollView {
                VStack(spacing: 16) {

                    if remote.connection.isConnected {
                        NowPlayingScreen()
                    } else {
                        EmptyStatePanel(onOpenSettings: { showSettings = true })
                    }

                    if let error = remote.lastError {
                        ErrorBanner(message: error)
                    }

                    footer
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                // 为底部两个悬浮胶囊预留空间，绝不遮挡控制。
                .padding(.bottom, 96)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable {
                await remote.refreshNow()
                await remote.refreshMetadataNow()
            }

        .overlay(alignment: .bottomLeading) {
            if remote.connection.isConnected, remote.lyric != nil {
                LyricPillButton { showLyric = true }
                    .padding(.leading, 18)
                    .padding(.bottom, 18)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: remote.connection)
    }

    /// 纤细顶部状态栏：连接状态 + 设置入口（诊断 / 版本在设置工具栏内）。
    private var slimHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("SPlayer 遥控器")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            ConnectionBadge(
                state: remote.connection,
                isStale: remote.isStale,
                transport: remote.transport
            )
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
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
