import SwiftUI

@main
struct SPlayerRemoteApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var remote: RemoteViewModel

    init() {
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _remote = StateObject(wrappedValue: RemoteViewModel(
            settings: settings,
            socketFactory: URLSessionWebSocketTransport.makeFactory(),
            liveActivity: SPlayerRemoteApp.makeLiveActivityPresenter(settings: settings),
            intentSessionStore: .shared
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(remote)
        }
    }

    /// 生产 Live Activity 呈现；系统不支持 / 权限不可用时退回空实现（绝不谎报可用）。
    private static func makeLiveActivityPresenter(settings: SettingsStore) -> LiveActivityPresenting {
        #if canImport(ActivityKit)
        if #available(iOS 17.0, *) {
            return LiveActivityController(userEnabled: settings.liveActivityEnabled)
        }
        #endif
        return NoopLiveActivityPresenter()
    }
}
