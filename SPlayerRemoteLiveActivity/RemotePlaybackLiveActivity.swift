import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// 播放控制 Live Activity：锁屏卡片 + 灵动岛（紧凑 / 最小 / 展开）。
///
/// 视图只读渲染内容状态；所有交互按钮都是 `RemoteControlIntent`（由 App 进程执行），
/// 扩展本身**不做任何网络请求**。
struct RemotePlaybackLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteActivityAttributes.self) { context in
            LockScreenCard(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title.isEmpty ? "SPlayer" : context.state.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if !context.state.artist.isEmpty {
                            Text(context.state.artist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusGlyph(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ControlRow(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
            } minimal: {
                Image(systemName: "music.note")
            }
            .keylineTint(.orange)
        }
    }
}

private struct LockScreenCard: View {
    let state: RemoteActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title.isEmpty ? "SPlayer" : state.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !state.artist.isEmpty {
                        Text(state.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                StatusGlyph(state: state, isStale: isStale)
            }
            ControlRow(state: state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}

private struct StatusGlyph: View {
    let state: RemoteActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if isStale {
                Label("可能已过期", systemImage: "clock.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !state.connectionAvailable {
                Label("连接不可用", systemImage: "wifi.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if state.isBuffering {
                Label("缓冲中", systemImage: "ellipsis")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 新鲜度：相对时间戳，便于用户判断状态是否过期。
            Text(state.lastUpdate, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ControlRow: View {
    let state: RemoteActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 22) {
            Button(intent: RemoteControlIntent(command: .previous)) {
                Image(systemName: "backward.fill")
            }
            .accessibilityLabel("上一曲")

            Button(intent: RemoteControlIntent(command: state.isPlaying ? .pause : .play)) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .accessibilityLabel(state.isPlaying ? "暂停" : "播放")

            Button(intent: RemoteControlIntent(command: .next)) {
                Image(systemName: "forward.fill")
            }
            .accessibilityLabel("下一曲")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
    }
}
