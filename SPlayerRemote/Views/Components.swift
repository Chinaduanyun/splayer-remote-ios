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

// MARK: - 正在播放主面板

/// 「正在播放」主屏：大封面 + 标题 / 艺人 + 单一进度条 + 大控制簇。
///
/// 设计约定（v1.3 重排）：
/// - 不再重复解释元数据、不再使用巨大的状态标题；
/// - 只保留**一个进度滑杆**；音量只在右侧扬声器按钮的 popover 中出现；
/// - 点播待确认 / 协作状态只以一行克制的副文案呈现，不遮挡控制；
/// - 所有命中区 ≥44pt，支持动态字体与 VoiceOver。
struct NowPlayingScreen: View {
    @EnvironmentObject private var remote: RemoteViewModel
    @State private var showsVolume = false

    var body: some View {
        VStack(spacing: 18) {
            ArtworkHeroView(url: remote.currentTrack?.coverURL)

            VStack(spacing: 6) {
                Text(titleText)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let tertiary = tertiaryText {
                    Text(tertiary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            // 紧凑状态行：播放状态 + 音量 popover 按钮。
            HStack(spacing: 10) {
                Text(remote.playbackState.displayName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                if remote.isBuffering {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
                Button {
                    showsVolume.toggle()
                } label: {
                    Image(systemName: remote.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
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

            TransportCluster()

            if let notice = collaborationNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("提示：\(notice)")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .glassPanel()
    }

    private var titleText: String {
        if let title = remote.currentTrack?.title { return title }
        if let id = remote.songId { return "曲目 #\(id)" }
        return "尚未获取曲目"
    }

    private var subtitleText: String {
        if let artist = remote.currentTrack?.artistLine { return artist }
        if let id = remote.songId { return "歌曲标识 #\(id)" }
        return "等待播放数据"
    }

    /// 克制的来源 / 专辑副标题；缺失时不编造。
    private var tertiaryText: String? {
        guard let track = remote.currentTrack else { return nil }
        var parts: [String] = []
        if let album = track.album?.name, !album.isEmpty { parts.append(album) }
        if let source = track.source, !source.isEmpty { parts.append(source.uppercased()) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var collaborationNotice: String? {
        if let pending = remote.pendingPlayback {
            return "切歌确认中：#\(pending.trackId)（待权威状态确认）"
        }
        return remote.collaborationMessage
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
/// 仅松手时上报一次，绝不自动重试。只在扬声器按钮的 popover 中呈现。
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

// MARK: - 交通控制簇

/// 大号控制簇：上一曲 / 播放暂停 / 下一曲；停止等次要操作收入菜单。
struct TransportCluster: View {
    @EnvironmentObject private var remote: RemoteViewModel

    var body: some View {
        HStack(spacing: 16) {
            GlassTransportButton(systemImage: "backward.fill", label: "上一曲", enabled: remote.canControl) {
                remote.send(.prev)
            }

            GlassTransportButton(
                systemImage: remote.playbackState.isPlaying ? "pause.fill" : "play.fill",
                label: remote.playbackState.isPlaying ? "暂停" : "播放",
                prominent: true,
                enabled: remote.canControl,
                large: true
            ) {
                remote.send(remote.playbackState.isPlaying ? .pause : .play)
            }

            GlassTransportButton(systemImage: "forward.fill", label: "下一曲", enabled: remote.canControl) {
                remote.send(.next)
            }

            Menu {
                Button {
                    remote.send(.stop)
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(!remote.canControl)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("更多控制")
        }
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
