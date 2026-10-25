import XCTest
import Combine
@testable import SPlayerRemote

final class SettingsStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultsToPort6688AndEmptyHost() {
        let store = SettingsStore(defaults: makeDefaults(), tokenStore: InMemoryTokenStore())
        XCTAssertEqual(store.host, "")
        XCTAssertEqual(store.portText, "6688")
        XCTAssertEqual(store.token, "")
    }

    func testLoadsTokenFromInjectedStore() {
        let store = SettingsStore(defaults: makeDefaults(), tokenStore: InMemoryTokenStore(stored: "abc"))
        XCTAssertEqual(store.token, "abc")
    }

    func testHostAndPortPersistButTokenDoesNot() throws {
        let defaults = makeDefaults()
        let tokenStore = InMemoryTokenStore()
        let store = SettingsStore(defaults: defaults, tokenStore: tokenStore)

        store.host = "192.168.31.100"
        store.portText = "6688"
        store.token = "topsecret"
        store.persistConnectionSettings()
        try store.persistToken()

        XCTAssertEqual(tokenStore.stored, "topsecret")

        // Token 不应出现在 UserDefaults 中。
        let persisted = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        XCTAssertFalse(persisted.contains("topsecret"), "Token 泄漏到了 UserDefaults: \(persisted)")

        // host/port 应可从同 suite 重新读回。
        let reloaded = SettingsStore(defaults: defaults, tokenStore: tokenStore)
        XCTAssertEqual(reloaded.host, "192.168.31.100")
        XCTAssertEqual(reloaded.portText, "6688")
    }

    func testPersistTokenFailureSurfacesError() {
        let tokenStore = InMemoryTokenStore()
        tokenStore.saveShouldFail = true
        let store = SettingsStore(defaults: makeDefaults(), tokenStore: tokenStore)
        store.token = "abc"

        XCTAssertThrowsError(try store.persistToken())
        XCTAssertNotNil(store.keychainError)
    }

    func testClearTokenRemovesFromStore() throws {
        let tokenStore = InMemoryTokenStore(stored: "abc")
        let store = SettingsStore(defaults: makeDefaults(), tokenStore: tokenStore)
        try store.clearToken()
        XCTAssertNil(tokenStore.stored)
        XCTAssertEqual(store.token, "")
    }

    func testMakeBaseURLValidates() throws {
        let store = SettingsStore(defaults: makeDefaults(), tokenStore: InMemoryTokenStore())
        store.host = "192.168.31.100"
        store.portText = "6688"
        let url = try store.makeBaseURL()
        XCTAssertEqual(url.absoluteString, "http://192.168.31.100:6688/api/external")

        store.host = "http://evil.example"
        XCTAssertThrowsError(try store.makeBaseURL())
    }

    // MARK: - 不可变配置 / 原子保存

    func testMakeConfigurationUsesCommittedValues() throws {
        let store = SettingsStore(defaults: makeDefaults(), tokenStore: InMemoryTokenStore(stored: "tok"))
        store.host = "192.168.31.100"
        store.portText = "6688"
        store.useWebSocket = true

        let configuration = try store.makeConfiguration()
        XCTAssertEqual(configuration.baseURL.absoluteString, "http://192.168.31.100:6688/api/external")
        XCTAssertEqual(configuration.token, "tok")
        XCTAssertTrue(configuration.useWebSocket)
    }

    func testSaveConfigurationCommitsAndPersistsPreferences() throws {
        let defaults = makeDefaults()
        let tokenStore = InMemoryTokenStore()
        let store = SettingsStore(defaults: defaults, tokenStore: tokenStore)

        try store.saveConfiguration(
            host: "192.168.31.100",
            portText: "7000",
            token: "newtoken",
            useWebSocket: false,
            autoConnect: true
        )

        XCTAssertEqual(store.host, "192.168.31.100")
        XCTAssertEqual(store.portText, "7000")
        XCTAssertEqual(store.token, "newtoken")
        XCTAssertFalse(store.useWebSocket)
        XCTAssertTrue(store.autoConnect)
        XCTAssertEqual(tokenStore.stored, "newtoken")
        XCTAssertTrue(store.hasSavedConnection)

        let reloaded = SettingsStore(defaults: defaults, tokenStore: tokenStore)
        XCTAssertEqual(reloaded.host, "192.168.31.100")
        XCTAssertEqual(reloaded.portText, "7000")
        XCTAssertFalse(reloaded.useWebSocket)
        XCTAssertTrue(reloaded.autoConnect)
    }

    func testSaveConfigurationKeychainFailureCommitsNothing() {
        let defaults = makeDefaults()
        let tokenStore = InMemoryTokenStore(stored: "old")
        let store = SettingsStore(defaults: defaults, tokenStore: tokenStore)
        store.host = "192.168.31.100"
        store.portText = "6688"
        store.token = "old"
        store.persistConnectionSettings()

        tokenStore.saveShouldFail = true
        XCTAssertThrowsError(try store.saveConfiguration(
            host: "10.0.0.9",
            portText: "9000",
            token: "leaked",
            useWebSocket: false,
            autoConnect: true
        ))

        // 未保存的 host/token 不得泄漏到已保存配置。
        XCTAssertEqual(store.host, "192.168.31.100")
        XCTAssertEqual(store.portText, "6688")
        XCTAssertEqual(store.token, "old")
        XCTAssertEqual(tokenStore.stored, "old")
        XCTAssertNotNil(store.keychainError)
        let persistedHost = defaults.string(forKey: SettingsStore.Keys.host)
        XCTAssertEqual(persistedHost, "192.168.31.100")
    }

    func testSaveConfigurationInvalidHostCommitsNothing() {
        let store = SettingsStore(defaults: makeDefaults(), tokenStore: InMemoryTokenStore(stored: "old"))
        store.host = "192.168.31.100"
        store.portText = "6688"

        XCTAssertThrowsError(try store.saveConfiguration(
            host: "http://evil",
            portText: "6688",
            token: "leaked",
            useWebSocket: true,
            autoConnect: false
        ))
        XCTAssertEqual(store.host, "192.168.31.100")
        XCTAssertNotEqual(store.token, "leaked")
    }
}
