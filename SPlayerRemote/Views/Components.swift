import SwiftUI

// MARK: - 状态徽标

struct ConnectionBadge: View {
    let state: RemoteViewModel.ConnectionState

    private var text: String {
        switch state {
        case .disconnected: return "未连接"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .failed: return "连接失败"
        }
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("连接状态：\(text)")
    }
}

// MARK: - 播放状态 + 元数据面板

struct PlaybackStatusPanel: View {
    @EnvironmentObject private var remote: RemoteViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(remote.playbackState.displayName)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                Spacer()
                if let info = remote.info {
                    Text("v\(info.version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ProgressSection()

            VolumeSection()

            MetadataExplanation(songId: remote.nowPlaying?.songId)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }
}

/// 进度：轮询显示，拖动时使用本地草稿，松手才上报。
private struct ProgressSection: View {
    @EnvironmentObject private var remote: RemoteViewModel

    private var duration: Double { Double(remote.currentDurationMs) }
    private var position: Double {
        remote.seekDraft ?? Double(remote.currentPositionMs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Slider(
                value: Binding(
                    get: { min(max(position, 0), max(duration, 1)) },
                    set: { remote.seekDraft = $0 }
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
                Text(formatTime(duration)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// 音量：同样只在松手时上报。
private struct VolumeSection: View {
    @EnvironmentObject private var remote: RemoteViewModel

    private var volume: Double {
        remote.volumeDraft ?? remote.currentVolume
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
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
            .accessibilityLabel("音量")
            .accessibilityValue(Text("\(Int((min(max(volume, 0), 1)) * 100))%"))

            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// 上游 API 不提供标题 / 艺人 / 封面，这里如实说明，不伪造任何元数据。
private struct MetadataExplanation: View {
    let songId: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("歌曲标识")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(songId.map { "#\($0)" } ?? "—")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("SPlayer 外部 API 仅返回歌曲 ID、进度与音量，不提供标题、艺人或封面图片，因此本 App 不会虚构这些信息。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 交通控制面板

struct TransportCluster: View {
    @EnvironmentObject private var remote: RemoteViewModel

    var body: some View {
        HStack(spacing: 18) {
            GlassTransportButton(systemImage: "backward.fill", label: "上一曲", enabled: remote.canControl) {
                remote.send(.prev)
            }
            GlassTransportButton(systemImage: "stop.fill", label: "停止", enabled: remote.canControl) {
                remote.send(.stop)
            }
            GlassTransportButton(
                systemImage: remote.playbackState.isPlaying ? "pause.fill" : "play.fill",
                label: remote.playbackState.isPlaying ? "暂停" : "播放",
                prominent: true,
                enabled: remote.canControl
            ) {
                remote.send(remote.playbackState.isPlaying ? .pause : .play)
            }
            GlassTransportButton(systemImage: "forward.fill", label: "下一曲", enabled: remote.canControl) {
                remote.send(.next)
            }
        }
        .padding(.vertical, 14)
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
