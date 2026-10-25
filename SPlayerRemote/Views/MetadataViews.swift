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

// MARK: - 当前曲目元数据

/// 主屏元数据：封面 + 标题 / 艺人 / 专辑 / 来源。
/// 元数据不可用时改为诚实的说明，绝不伪造标题或封面。
struct NowPlayingMetadataSection: View {
    @EnvironmentObject private var remote: RemoteViewModel
    @State private var showLyric = false

    var body: some View {
        if let track = remote.currentTrack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    CoverImageView(url: track.coverURL, size: 72)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title ?? "未知标题")
                            .font(.headline)
                            .lineLimit(2)
                        Text(track.artistLine ?? "未知艺人")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let album = track.album?.name {
                            Text(album)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            if let source = track.source {
                                Text(source.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            if let duration = track.durationText {
                                Text(duration)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    if remote.lyric != nil {
                        Button {
                            showLyric = true
                        } label: {
                            Label("歌词", systemImage: "text.quote")
                                .font(.footnote.weight(.semibold))
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                    }
                    Text(remote.songId.map { "#\($0)" } ?? "—")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
            .sheet(isPresented: $showLyric) {
                LyricSheet(document: remote.lyric, positionMs: remote.currentPositionMs)
            }
        } else {
            MetadataUnavailableNotice()
        }
    }
}

/// 元数据不可用时的诚实提示；不影响控制能力。
struct MetadataUnavailableNotice: View {
    @EnvironmentObject private var remote: RemoteViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("曲目元数据不可用")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(remote.songId.map { "#\($0)" } ?? "—")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hint: String {
        switch remote.metadataState {
        case .loading:
            return "正在获取局域网分享的曲目信息…"
        case .unavailable:
            return "SPlayer 的局域网分享未开启，或未返回队列，仅显示歌曲标识。播放控制不受影响。"
        case .idle, .available:
            return "尚未获取到局域网分享的曲目信息。"
        }
    }
}

// MARK: - 队列浮标 + 队列面板

/// 右下角悬浮胶囊：队列图标 + 曲目数量。点击打开只读队列面板。
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
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassPanel(cornerRadius: 22)
        .accessibilityLabel("播放队列，共 \(remote.queue?.trackCount ?? 0) 首")
    }
}

/// 只读队列浏览面板：高亮当前曲目，点击行展开信息（**不**提供选曲 / 播放）。
struct QueueSheet: View {
    @EnvironmentObject private var remote: RemoteViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedId: String?

    var body: some View {
        NavigationStack {
            Group {
                if let queue = remote.queue, !queue.tracks.isEmpty {
                    List(queue.tracks) { track in
                        Button {
                            selectedId = (selectedId == track.id) ? nil : track.id
                        } label: {
                            QueueRow(
                                track: track,
                                isCurrent: track.id == remote.currentTrack?.id,
                                expanded: selectedId == track.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                } else {
                    EmptyQueueNotice()
                }
            }
            .navigationTitle("播放队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("只读浏览：上游未提供选曲接口，点击曲目仅展开信息，不会切换播放。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(10)
            }
        }
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

private struct QueueRow: View {
    let track: LanShareTrack
    let isCurrent: Bool
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                }
                if let duration = track.durationText {
                    Text(duration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    if let album = track.album?.name {
                        Text("专辑：\(album)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let source = track.source {
                        Text("来源：\(source)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("歌曲标识：#\(track.id)").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
