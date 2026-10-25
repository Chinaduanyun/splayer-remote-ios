import XCTest
@testable import SPlayerRemote

@MainActor
final class RemoteViewModelTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "test-vm-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeViewModel(
        api: MockRemoteAPI
    ) -> RemoteViewModel {
        let settings = SettingsStore(defaults: makeDefaults(), tokenStore: InMemoryTokenStore(stored: "t"))
        settings.host = "192.168.31.100"
        settings.portText = "6688"
        return RemoteViewModel(settings: settings, tokenStore: InMemoryTokenStore(), clientFactory: { _, _ in api })
    }

    func testConnectSuccessMarksConnected() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        XCTAssertTrue(vm.connection.isConnected)
        XCTAssertEqual(vm.info?.version, "9.9.9")
        XCTAssertEqual(vm.status?.state, .playing)
        XCTAssertEqual(vm.nowPlaying?.songId, 42)
    }

    func testConnectFailsWhenInfoFails() async {
        let api = MockRemoteAPI()
        api.infoResult = .failure(RemoteAPIError.transport("boom"))
        let vm = makeViewModel(api: api)
        await vm.connect()

        guard case .failed = vm.connection else {
            return XCTFail("应处于 failed，实际 \(vm.connection)")
        }
        XCTAssertNotNil(vm.lastError)
    }

    func testConnectUnauthorizedSurfacesAuthMessage() async {
        let api = MockRemoteAPI()
        api.infoResult = .failure(RemoteAPIError.unauthorized)
        let vm = makeViewModel(api: api)
        await vm.connect()

        guard case .failed(let message) = vm.connection else {
            return XCTFail("应处于 failed，实际 \(vm.connection)")
        }
        XCTAssertTrue(message.contains("401"), message)
    }

    func testInvalidHostFailsWithoutRequest() async {
        let api = MockRemoteAPI()
        let settings = SettingsStore(defaults: makeDefaults(), tokenStore: InMemoryTokenStore())
        settings.host = "http://evil"
        settings.portText = "6688"
        let vm = RemoteViewModel(settings: settings, tokenStore: InMemoryTokenStore(), clientFactory: { _, _ in api })
        await vm.connect()

        guard case .failed = vm.connection else {
            return XCTFail("应处于 failed，实际 \(vm.connection)")
        }
    }

    func testCommandsIgnoredWhenDisconnected() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        vm.send(.play)
        await Task.yield()
        XCTAssertTrue(api.sentCommands.isEmpty)
    }

    func testCommandSentWhenConnected() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        vm.send(.play)
        await waitUntil { !api.sentCommands.isEmpty }
        XCTAssertEqual(api.sentCommands, [.play])
    }

    func testVolumeCommitClampsAndSendsOnce() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        vm.volumeDraft = 5
        vm.setVolumeAdjusting(false) // 松手 -> 上报
        await waitUntil { !api.setVolumes.isEmpty }
        XCTAssertEqual(api.setVolumes, [1.0])
    }

    func testSeekCommitClampsToDuration() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        await vm.connect()
        defer { vm.disconnect() }

        vm.seekDraft = 9_999_999
        vm.setSeekAdjusting(false)
        await waitUntil { !api.soughtPositions.isEmpty }
        XCTAssertEqual(api.soughtPositions, [240_000])
    }

    func testMessageLocalizesKnownErrors() async {
        let api = MockRemoteAPI()
        let vm = makeViewModel(api: api)
        XCTAssertTrue(vm.message(for: RemoteAPIError.unauthorized).contains("401"))
        XCTAssertTrue(vm.message(for: RemoteAPIError.forbidden).contains("403"))
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待超时", file: file, line: line)
    }
}
