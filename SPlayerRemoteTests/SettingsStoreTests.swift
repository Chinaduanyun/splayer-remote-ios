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
}
