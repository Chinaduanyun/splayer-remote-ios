import SwiftUI
import WidgetKit

/// Live Activity 扩展入口：只承载播放控制 Live Activity，绝不直接联网。
@main
struct SPlayerRemoteLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        RemotePlaybackLiveActivity()
    }
}
