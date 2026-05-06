import XCTest

@testable import AppleMailBlade

final class ConfigTests: XCTestCase {

    func testDefaultPathValidates() throws {
        let config = try MailBladeConfig()
        XCTAssertTrue(config.storePath.contains("Library/Mail/V10/MailData/Envelope Index"))
    }

    func testTmpPathIsAccepted() throws {
        let path = "/private/tmp/test-\(UUID().uuidString)/Envelope Index"
        let config = try MailBladeConfig(storePath: path)
        XCTAssertEqual(config.storePath, path)
    }

    func testArbitraryPathIsRejected() {
        XCTAssertThrowsError(try MailBladeConfig(storePath: "/etc/passwd")) { error in
            guard case MailBladeError.invalidStorePath(let path) = error else {
                return XCTFail("expected invalidStorePath, got \(error)")
            }
            XCTAssertEqual(path, "/etc/passwd")
        }
    }

    func testTraversalPathIsRejected() {
        // Attempt to escape the canonical prefix via `..` segment.
        let path = "/private/tmp/foo/../../../../etc/passwd"
        XCTAssertThrowsError(try MailBladeConfig(storePath: path)) { error in
            guard case MailBladeError.invalidStorePath = error else {
                return XCTFail("expected invalidStorePath, got \(error)")
            }
        }
    }

    func testHardCapClampsToAtLeastOne() throws {
        let config = try MailBladeConfig(maxResultsHardCap: 0)
        XCTAssertEqual(config.maxResultsHardCap, 1)
    }

    func testAttachmentCapDefaults25MB() throws {
        let config = try MailBladeConfig()
        XCTAssertEqual(config.maxAttachmentBytes, 25 * 1024 * 1024)
    }

    func testMessageCapDefaults100MB() throws {
        let config = try MailBladeConfig()
        XCTAssertEqual(config.maxMessageBytes, 100 * 1024 * 1024)
    }

    func testMultipartDepthDefault32() throws {
        let config = try MailBladeConfig()
        XCTAssertEqual(config.maxMultipartDepth, 32)
    }
}
