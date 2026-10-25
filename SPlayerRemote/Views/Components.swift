import SwiftUI

// MARK: - 状态徽标

/// 连接徽标：区分「连接状态」「数据过期」「传输通道」，避免过期时仍显示为健康绿色。
struct ConnectionBadge: View {
    let state: RemoteViewModel.ConnectionState
    var isStale: Bool = false
    var transport: RemoteViewModel.TransportState = .disabled

    private var text: String {
        if isStale, state.isConnected { return "数据过期" }
        switch state {
        case .disconnected: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .failed: return "连接失败"
        }
    }

    private var color: Color {
        if isStale, state.isConnected { return .orange }
        switch state {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var showsTransport: Bool {
        state.isConnected && transport != .disabled
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.footnote.weight(.medium))
            if showsTransport {
                Text(transport.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("连接状态：\(text)\(showsTransport ? "，通道：\(transport.displayName)" : "")")
    }
}

// MARK: - 播放状态 + 元数据面板

struct PlaybackStatusPanel: View {
    @EnvironmentObject private var remote: RemoteViewModel
    @State private var showsVolume = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(remote.playbackState.displayName)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    showsVolume.toggle()
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("调节播放音量")
                .popover(isPresented: $showsVolume) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("播放音量").font(.headline)
                        VolumeSection()
                    }
                    .padding(20)
                    .frame(width: 280)
                    .presentationCompactAdaptation(.popover)
                }
            }

            ProgressSection()

            NowPlayingMetadataSection()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }
}

/// 进度：`TimelineView` 本地重绘平滑外推，拖动时使用本地草稿，松手才上报。
private struct ProgressSection: View {
    @EnvironmentObject private var remote: RemoteViewModel
    @State private var showRemaining = false

    var body: some View {
        // 每秒本地重绘，不产生任何网络请求。
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            content
        }
    }

    private var content: some View {
        let duration = Double(remote.currentDurationMs)
        let position = remote.seekDraft ?? Double(remote.currentPositionMs)

        return VStack(alignment: .leading, spacing: 10) {
            Slider(
                value: Binding(
                    get: { min(max(position, 0), max(duration, 1)) },
                    set: { remote.updateSeekDraft($0) }
                ),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in remote.setSeekAdjusting(editing) }
            )
            .tint(Theme.accent)
            .disabled(!remote.canControl || duration <= 0)
            .accessibilityLabel("播放进度")
            .accessibilityValue(Text("\(formatTime(position)) / \(formatTime(duration))"))

            HStack {
                Text(formatTime(position)).monospacedDigit()
                Spacer()
                Button {
                    showRemaining.toggle()
                } label: {
                    Text(showRemaining ? "-\(formatTime(max(duration - position, 0)))" : formatTime(duration))
                        .monospacedDigit()
                        .font(.caption.weight(.medium))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(showRemaining ? "切换为总时长" : "切换为剩余时间")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        }
    }
}

/// 音量：仅保留滑杆 + 百分比，控制的是 **Android 端播放音量**，不是手机系统音量。
/// 仅松手时上报一次，绝不自动重试。（静音 / 步进 / 预设快捷按钮已按 V1.2 需求移除。）
private struct VolumeSection: View {
    @EnvironmentObject private var remote: RemoteViewModel

    private var volume: Double {
        remote.volumeDraft ?? remote.currentVolume
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: remote.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Slider(
                    value: Binding(
                        get: { min(max(volume, 0), 1) },
                        set: { remote.volumeDraft = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in remote.setVolumeAdjusting(editing) }
                )
                .tint(Theme.accent)
                .disabled(!remote.canControl)
                .accessibilityLabel("播放音量")
                .accessibilityValue(Text("\(Int((min(max(volume, 0), 1)) * 100))%"))

                Text("\(Int((min(max(volume, 0), 1)) * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
            }
        }
    }
}

/// 音量快捷按钮已按 V1.2 需求移除（静音 / ±5% / 25-100 预设）。

// MARK: - 交通控制面板

struct TransportCluster: View {
    @EnvironmentObject private var remote: RemoteViewModel

    var body: some View {
        VStack(spacing: 12) {
            // 主控制：更大的播放 / 暂停按钮。
            GlassTransportButton(
                systemImage: remote.playbackState.isPlaying ? "pause.fill" : "play.fill",
                label: remote.playbackState.isPlaying ? "暂停" : "播放",
                prominent: true,
                enabled: remote.canControl,
                large: true
            ) {
                remote.send(remote.playbackState.isPlaying ? .pause : .play)
            }

            // 次级控制：上一曲 / 停止 / 下一曲分组。
            HStack(spacing: 18) {
                GlassTransportButton(systemImage: "backward.fill", label: "上一曲", enabled: remote.canControl) {
                    remote.send(.prev)
                }
                GlassTransportButton(systemImage: "stop.fill", label: "停止", enabled: remote.canControl) {
                    remote.send(.stop)
                }
                GlassTransportButton(systemImage: "forward.fill", label: "下一曲", enabled: remote.canControl) {
                    remote.send(.next)
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .glassPanel(cornerRadius: 32)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 时间格式化

func formatTime(_ milliseconds: Double) -> String {
    guard milliseconds.isFinite, milliseconds > 0 else { return "0:00" }
    let totalSeconds = Int(milliseconds / 1000)
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%d:%02d", minutes, seconds)
}
