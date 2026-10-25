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
            socketFactory: URLSessionWebSocketTransport.makeFactory()
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(remote)
        }
    }
}
