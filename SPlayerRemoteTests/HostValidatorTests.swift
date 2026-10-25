import XCTest
@testable import SPlayerRemote

final class HostValidatorTests: XCTestCase {

    // MARK: - 合法输入

    func testNormalizesIPv4() throws {
        XCTAssertEqual(try HostValidator.normalizeHost("192.168.31.100"), "192.168.31.100")
        XCTAssertEqual(try HostValidator.normalizeHost("  10.0.0.5  "), "10.0.0.5")
    }

    func testNormalizesHostnameAndLocal() throws {
        XCTAssertEqual(try HostValidator.normalizeHost("MyPhone.local"), "myphone.local")
        XCTAssertEqual(try HostValidator.normalizeHost("localhost"), "localhost")
        XCTAssertEqual(try HostValidator.normalizeHost("splayer-host"), "splayer-host")
    }

    func testNormalizesIPv6WithAndWithoutBrackets() throws {
        XCTAssertEqual(try HostValidator.normalizeHost("[fe80::1]"), "fe80::1")
        XCTAssertEqual(try HostValidator.normalizeHost("::1"), "::1")
    }

    func testBuildsBaseURLFromIPv4() throws {
        let url = try HostValidator.buildBaseURL(host: "192.168.31.100", port: 6688)
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "192.168.31.100")
        XCTAssertEqual(url.port, 6688)
        XCTAssertEqual(url.path, "/api/external")
        XCTAssertNil(url.user)
        XCTAssertNil(url.query)
    }

    func testBuildsBaseURLFromIPv6WithBrackets() throws {
        let url = try HostValidator.buildBaseURL(host: "::1", port: 6688)
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.port, 6688)
        // IPv6 字面量必须被方括号包裹。
        XCTAssertTrue(url.absoluteString.contains("[::1]"), "得到 \(url.absoluteString)")
    }

    // MARK: - 非法输入

    func testRejectsScheme() {
        XCTAssertThrowsError(try HostValidator.normalizeHost("http://192.168.1.10")) { error in
            XCTAssertEqual(error as? HostValidator.ValidationError, .containsScheme)
        }
    }

    func testRejectsPathQueryFragment() {
        XCTAssertEqual(try? HostValidator.normalizeHost("192.168.1.10/api"), nil)
        XCTAssertEqual(try? HostValidator.normalizeHost("192.168.1.10?x=1"), nil)
        XCTAssertEqual(try? HostValidator.normalizeHost("host#frag"), nil)
    }

    func testRejectsUserInfo() {
        XCTAssertThrowsError(try HostValidator.normalizeHost("user@192.168.1.10")) { error in
            XCTAssertEqual(error as? HostValidator.ValidationError, .containsUserInfo)
        }
    }

    func testRejectsEmpty() {
        XCTAssertThrowsError(try HostValidator.normalizeHost("   ")) { error in
            XCTAssertEqual(error as? HostValidator.ValidationError, .empty)
        }
    }

    func testRejectsInvalidHostname() {
        XCTAssertEqual(try? HostValidator.normalizeHost("bad host!"), nil)
        XCTAssertEqual(try? HostValidator.normalizeHost("-leading.example"), nil)
        XCTAssertEqual(try? HostValidator.normalizeHost("999.999.999.999"), nil)
    }

    func testRejectsInvalidPort() {
        XCTAssertEqual(try? HostValidator.normalizePort("0"), nil)
        XCTAssertEqual(try? HostValidator.normalizePort("65536"), nil)
        XCTAssertEqual(try? HostValidator.normalizePort("abc"), nil)
        XCTAssertEqual(try? HostValidator.normalizePort(""), nil)
    }

    func testAcceptsPortBounds() throws {
        XCTAssertEqual(try HostValidator.normalizePort("1"), 1)
        XCTAssertEqual(try HostValidator.normalizePort("65535"), 65535)
        XCTAssertEqual(try HostValidator.normalizePort(" 6688 "), 6688)
    }
}
