import SwiftUI
import UIKit

// MARK: - 封面

/// 封面视图：使用**独立、无凭据**的 `CoverImageLoader`，失败 / 缺失时显示占位符。
struct CoverImageView: View {
    let url: URL?
    var size: CGFloat = 64

    @State private var image: UIImage?
    @State private var failed = false
    @State private var requestID = UUID()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: failed ? "music.note" : "photo")
                    .font(.system(size: size * 0.34))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .task(id: url) {
            let currentRequest = UUID()
            requestID = currentRequest
            await load(url, requestID: currentRequest)
        }
        .accessibilityHidden(true)
    }

    private func load(_ target: URL?, requestID currentRequest: UUID) async {
        // URL 变化时立即清空旧图，避免展示上一首封面。
        image = nil
        failed = false
        guard let target else { return }

        if let cached = CoverImageLoader.shared.cachedImage(for: target) {
            guard !Task.isCancelled, requestID == currentRequest, url == target else { return }
            image = cached
            return
        }

        let loaded = await CoverImageLoader.shared.image(for: target)
        // 只有仍为当前请求（未被取消 / URL 未变）时才写入结果，避免慢 A 覆盖快 B。
        guard !Task.isCancelled, requestID == currentRequest, url == target else { return }
        image = loaded
        failed = loaded == nil
    }
}

/// 大尺寸自适应封面：随可用宽度缩放并保持 1:1；无真实封面时显示占位符，绝不伪造。
/// 竖屏 / 横屏 / 动态字体下都不会溢出，且最大宽度受控，保持版面克制。
struct ArtworkHeroView: View {
    let url: URL?

    @State private var image: UIImage?
    @State private var failed = false
    @State private var requestID = UUID()

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.ultraThinMaterial)
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: failed ? "music.note" : "photo")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .frame(maxWidth: 300)
            .frame(maxWidth: .infinity)
            .task(id: url) {
                let currentRequest = UUID()
                requestID = currentRequest
                await load(url, requestID: currentRequest)
            }
            .accessibilityHidden(true)
    }

    private func load(_ target: URL?, requestID currentRequest: UUID) async {
        image = nil
        failed = false
        guard let target else { return }
        if let cached = CoverImageLoader.shared.cachedImage(for: target) {
            guard !Task.isCancelled, requestID == currentRequest, url == target else { return }
            image = cached
            return
        }
        let loaded = await CoverImageLoader.shared.image(for: target)
        guard !Task.isCancelled, requestID == currentRequest, url == target else { return }
        image = loaded
        failed = loaded == nil
    }
}

// MARK: - 队列浮标 + 歌词浮标

/// 右下角悬浮胶囊：队列图标 + 曲目数量。点击打开队列面板。
struct QueuePillButton: View {
    @EnvironmentObject private var remote: RemoteViewModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(remote.queue?.trackCount ?? 0)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                if remote.canSelectFromQueue {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassPanel(cornerRadius: 22)
        .accessibilityLabel("播放队列，共 \(remote.queue?.trackCount ?? 0) 首\(remote.canSelectFromQueue ? "，可点播" : "，只读")")
    }
}

/// 左下角悬浮胶囊：打开独立歌词面板，避免主屏堆叠冗长歌词。
struct LyricPillButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.system(size: 15, weight: .semibold))
                Text("歌词")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassPanel(cornerRadius: 22)
        .accessibilityLabel("打开歌词")
    }
}

/// 队列浏览面板：本地搜索 / 过滤当前队列；可控时支持点播（发送一次 playAt，待权威确认）。
struct QueueSheet: View {
    @EnvironmentObject private var remote: RemoteViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// (原始下标, 曲目) —— 保留下标以便点播时校验「行身份 + 下标」，解决重复 id 歧义。
    private var filtered: [(index: Int, track: LanShareTrack)] {
        guard let tracks = remote.queue?.tracks else { return [] }
        let indexed = Array(tracks.enumerated()).map { (index: $0.offset, track: $0.element) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return indexed }
        return indexed.filter { item in
            (item.track.title ?? "").localizedCaseInsensitiveContains(trimmed)
                || (item.track.artistLine ?? "").localizedCaseInsensitiveContains(trimmed)
                || (item.track.album?.name ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let queue = remote.queue, !queue.tracks.isEmpty {
                    if filtered.isEmpty {
                        ContentUnavailableCompat(message: "没有匹配的曲目。")
                    } else {
                        List {
                            ForEach(filtered, id: \.index) { item in
                                Button {
                                    guard remote.canSelectFromQueue else { return }
                                    remote.playQueueItem(trackId: item.track.id, index: item.index)
                                } label: {
                                    QueueRow(
                                        track: item.track,
                                        isCurrent: item.track.id == remote.currentTrack?.id,
                                        selectable: remote.canSelectFromQueue
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(!remote.canSelectFromQueue)
                            }
                        }
                        .listStyle(.plain)
                    }
                } else {
                    EmptyQueueNotice()
                }
            }
            .searchable(text: $query, prompt: "搜索当前队列")
            .navigationTitle("播放队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                QueuePermissionFooter()
            }
        }
    }
}

/// 队列权限 / 点播说明页脚：明确「只读 vs 可点播」，绝不夸大为全部歌单。
private struct QueuePermissionFooter: View {
    @EnvironmentObject private var remote: RemoteViewModel

    var body: some View {
        VStack(spacing: 6) {
            if let hint = remote.queueReadOnlyHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if remote.canSelectFromQueue {
                Text("点播只作用于主机**当前队列**；发送后等待权威播放状态确认，不重复发送。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if remote.collaborationState == .unauthorized || remote.collaborationState == .unavailable {
                Button {
                    remote.retryCollaborationAuthorization()
                } label: {
                    Label("重试协作授权", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            }
        }
        .padding(10)
    }
}

private struct EmptyQueueNotice: View {
    @EnvironmentObject private var remote: RemoteViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("暂无队列信息")
                .font(.headline)
            Text(remote.metadataState == .unavailable
                 ? "SPlayer 的局域网分享未开启，或尚未返回队列。"
                 : "正在获取队列…")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

/// 兼容旧系统的空态提示（避免直接使用 ContentUnavailableView 造成可用性分叉）。
private struct ContentUnavailableCompat: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

private struct QueueRow: View {
    let track: LanShareTrack
    let isCurrent: Bool
    let selectable: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            CoverImageView(url: track.coverURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title ?? "未知标题")
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Text(track.artistLine ?? "未知艺人")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("当前播放")
            } else if selectable {
                Image(systemName: "play.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let duration = track.durationText {
                Text(duration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title ?? "未知标题")，\(track.artistLine ?? "未知艺人")\(isCurrent ? "，当前播放" : "")")
    }
}

// MARK: - 歌词

/// LRC 歌词面板：按播放位置高亮，展示翻译行；不支持的格式优雅说明。
struct LyricSheet: View {
    let document: LanShareLyricDocument?
    let positionMs: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let document, !document.isSupported {
                    message("暂不支持该歌词格式（\(document.source.format)）。")
                } else if let document, document.lines.isEmpty {
                    message("暂无歌词。")
                } else if let document {
                    linesView(document)
                } else {
                    message("尚未获取到歌词。")
                }
            }
            .navigationTitle("歌词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func linesView(_ document: LanShareLyricDocument) -> some View {
        let highlight = document.lineIndex(forPositionMs: positionMs)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(document.lines.enumerated()), id: \.element.id) { index, line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.text)
                                .font(index == highlight ? .body.weight(.semibold) : .body)
                                .foregroundStyle(index == highlight ? Theme.accent : .primary)
                            if let translation = line.translation {
                                Text(translation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .onAppear {
                if let highlight {
                    proxy.scrollTo(document.lines[highlight].id, anchor: .center)
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "text.quote")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}
