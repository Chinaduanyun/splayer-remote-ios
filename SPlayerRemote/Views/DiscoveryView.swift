import SwiftUI

struct DiscoveryView: View {
    @EnvironmentObject private var remote: RemoteViewModel
    @StateObject private var model = DiscoveryViewModel()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("发现").font(.largeTitle.bold())
                Text(model.message).font(.callout).foregroundStyle(.secondary)
                if model.needsReconciliation {
                    Text("原命令需重新确认，当前队列暂只读。不会重新提交播放请求。")
                    Button("查询原命令状态（不重发）") { Task { await model.reconcile(remote: remote) } }
                }
                if model.capabilities != nil {
                    HStack {
                        Button("每日推荐") { Task { await model.query("discovery/daily-songs") } }
                        Button("心动推荐") { Task { await model.query("discovery/heart-songs") } }
                    }
                    Button("推荐歌单") { Task { await model.query("discovery/recommended-playlists") } }
                    Button("重试查询") { Task { await model.retryQuery() } }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))]) {
                        ForEach(model.playlists) { playlist in
                            Button { Task { await model.playlist(playlist.id) } } label: {
                                VStack(alignment: .leading) {
                                    CoverImageView(url: DiscoveryArtwork.sanitize(playlist.coverUrl), size: 120)
                                    Text(String(playlist.title.prefix(200))).lineLimit(2)
                                    Text("\(playlist.trackCount) 首").font(.caption)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    if let selection = model.selection {
                        if selection.items.isEmpty { Text("本页没有曲目。") }
                        ForEach(selection.items.indices, id: \.self) { index in
                            let track = selection.items[index]
                            Button { Task { await model.play(index, remote: remote) } } label: {
                                HStack {
                                    CoverImageView(url: track.artwork, size: 48)
                                    VStack(alignment: .leading) {
                                        Text(String(track.title.prefix(200))).lineLimit(2)
                                        Text(track.artists.prefix(8).map { String($0.name.prefix(100)) }.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle")
                                }.frame(minHeight: 52)
                            }.buttonStyle(.plain).disabled(!remote.canControl)
                        }
                        if selection.nextOffset != nil { Button("下一页（仅播放所选页）") { Task { await model.nextPage() } } }
                    }
                } else {
                    Button("重新检查增强版支持") { Task { await model.connect(remote: remote) } }
                }
                if model.busy || model.commandPending { ProgressView() }
            }
            .buttonStyle(.bordered)
            .disabled(model.busy || model.commandPending)
            .padding()
        }
        .task(id: "\(remote.generation)-\(remote.connection.isConnected)-\(remote.discoveryConfiguration != nil)") {
            await model.connect(remote: remote)
        }
    }
}
