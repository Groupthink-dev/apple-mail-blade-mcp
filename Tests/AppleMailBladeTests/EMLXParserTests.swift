import XCTest

@testable import AppleMailBlade

final class EMLXParserTests: XCTestCase {

    var parser: EMLXParser!

    override func setUp() {
        let config = try! MailBladeConfig(
            storePath: "/private/tmp/test-config-\(UUID().uuidString)/Envelope Index"
        )
        parser = EMLXParser(config: config)
    }

    // MARK: - Layer 1: envelope

    func testParseTextPlainExtractsBodyAndHeaders() throws {
        let data = SampleEMLXBuilder.emlxFromRFC822(SampleEMLXBuilder.textPlain)
        let result = try parser.parse(data, messageID: 1, includeHTML: false)
        XCTAssertNotNil(result.bodyText)
        XCTAssertTrue(result.bodyText?.contains("ahead of schedule") ?? false)
        XCTAssertEqual(result.headers["from"]?.first, "alice@example.com")
        XCTAssertEqual(result.headers["subject"]?.first, "Project status update")
        XCTAssertNil(result.bodyHTML)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    func testLengthPrefixMismatchSurfacesDecodeFailure() {
        // Construct a payload with a length prefix that exceeds the actual byte count.
        var data = Data()
        data.append(contentsOf: Array("9999\n".utf8))
        data.append(contentsOf: Array("From: alice@example.com\r\n".utf8))
        XCTAssertThrowsError(try parser.parse(data, messageID: 99, includeHTML: false)) { e in
            guard case MailBladeError.decodeFailure(let id, _) = e else {
                return XCTFail("expected decodeFailure")
            }
            XCTAssertEqual(id, 99)
        }
    }

    func testNonDigitInLengthPrefixSurfacesDecodeFailure() {
        var data = Data()
        data.append(contentsOf: Array("XYZ\n".utf8))
        data.append(contentsOf: Array("From: a\r\n".utf8))
        XCTAssertThrowsError(try parser.parse(data, messageID: 99, includeHTML: false))
    }

    func testEmptyBodyParsesCleanly() throws {
        let rfc822 = """
            From: a@example.com
            Subject: Empty body

            """
        let data = SampleEMLXBuilder.emlxFromRFC822(rfc822)
        let result = try parser.parse(data, messageID: 2, includeHTML: false)
        XCTAssertNil(result.bodyText)
        XCTAssertEqual(result.headers["subject"]?.first, "Empty body")
    }

    // MARK: - Layer 2: headers

    func testHeaderContinuationFolding() throws {
        let rfc822 = """
            From: a@example.com
            Subject: This is a long subject
             that wraps across two lines
            Content-Type: text/plain; charset=utf-8

            body
            """
        let data = SampleEMLXBuilder.emlxFromRFC822(rfc822)
        let result = try parser.parse(data, messageID: 3, includeHTML: false)
        XCTAssertEqual(
            result.headers["subject"]?.first,
            "This is a long subject that wraps across two lines"
        )
    }

    func testRFC2047QEncodedSubject() throws {
        let data = SampleEMLXBuilder.emlxFromRFC822(SampleEMLXBuilder.rfc2047EncodedHeaders)
        let result = try parser.parse(data, messageID: 4, includeHTML: false)
        XCTAssertEqual(result.headers["from"]?.first?.contains("Brädly"), true)
        XCTAssertEqual(result.headers["subject"]?.first?.contains("Test"), true)
        XCTAssertEqual(result.headers["subject"]?.first?.contains("Emoji"), true)
    }

    // MARK: - Layer 3: MIME walker

    func testMultipartAlternativeReturnsTextPlainByDefault() throws {
        let data = SampleEMLXBuilder.emlxFromRFC822(SampleEMLXBuilder.multipartAlternative)
        let result = try parser.parse(data, messageID: 5, includeHTML: false)
        XCTAssertEqual(
            result.bodyText,
            "This month: 5 articles on Apple silicon performance."
        )
        XCTAssertNil(result.bodyHTML)
    }

    func testMultipartAlternativeReturnsHTMLWhenRequested() throws {
        let data = SampleEMLXBuilder.emlxFromRFC822(SampleEMLXBuilder.multipartAlternative)
        let result = try parser.parse(data, messageID: 6, includeHTML: true)
        XCTAssertNotNil(result.bodyHTML)
        XCTAssertTrue(result.bodyHTML?.contains("<strong>5 articles</strong>") ?? false)
    }

    func testMultipartMixedEnumeratesAttachment() throws {
        let data = SampleEMLXBuilder.emlxFromRFC822(SampleEMLXBuilder.multipartMixedWithAttachment)
        let result = try parser.parse(data, messageID: 7, includeHTML: false)
        XCTAssertEqual(result.attachments.count, 1)
        let att = result.attachments[0]
        XCTAssertEqual(att.filename, "cradle-mountain.jpg")
        XCTAssertEqual(att.mimeType, "image/jpeg")
        XCTAssertNotNil(att.byteSize)
        XCTAssertNotNil(result.bodyText)
        XCTAssertTrue(result.bodyText?.contains("Tasmania") ?? false)
    }

    func testQuotedPrintableDecoding() throws {
        let data = SampleEMLXBuilder.emlxFromRFC822(SampleEMLXBuilder.quotedPrintable)
        let result = try parser.parse(data, messageID: 8, includeHTML: false)
        XCTAssertTrue(result.bodyText?.contains("café") ?? false)
        XCTAssertTrue(result.bodyText?.contains("—") ?? false)
    }

    func testBase64Decoding() throws {
        let data = SampleEMLXBuilder.emlxFromRFC822(SampleEMLXBuilder.base64Body)
        let result = try parser.parse(data, messageID: 9, includeHTML: false)
        XCTAssertTrue(result.bodyText?.contains("Thursday or Friday") ?? false)
    }

    // MARK: - Hardening guards

    func testMaxMessageBytesGuard() {
        let smallConfig = try! MailBladeConfig(
            storePath: "/private/tmp/test-cap-\(UUID().uuidString)/Envelope Index",
            maxMessageBytes: 1024
        )
        let smallParser = EMLXParser(config: smallConfig)
        // 2KB of bytes — exceeds 1KB cap.
        let big = Data(repeating: 0x41, count: 2048)
        var payload = Data()
        payload.append(contentsOf: Array("100\n".utf8))
        payload.append(big)
        XCTAssertThrowsError(
            try smallParser.parse(payload, messageID: 10, includeHTML: false)
        ) { e in
            guard case MailBladeError.decodeFailure(let id, let reason) = e else {
                return XCTFail("expected decodeFailure")
            }
            XCTAssertEqual(id, 10)
            XCTAssertTrue(reason.contains("maxMessageBytes"))
        }
    }

    func testMaxMultipartDepthGuard() {
        // Construct a deeply-nested multipart/mixed > maxMultipartDepth.
        let shallowConfig = try! MailBladeConfig(
            storePath: "/private/tmp/test-depth-\(UUID().uuidString)/Envelope Index",
            maxMultipartDepth: 2
        )
        let shallowParser = EMLXParser(config: shallowConfig)
        // 3 levels nested.
        let rfc822 = """
            From: a@example.com
            Content-Type: multipart/mixed; boundary="L1"

            --L1
            Content-Type: multipart/mixed; boundary="L2"

            --L2
            Content-Type: multipart/mixed; boundary="L3"

            --L3
            Content-Type: text/plain

            deepest
            --L3--
            --L2--
            --L1--
            """
        let data = SampleEMLXBuilder.emlxFromRFC822(rfc822)
        XCTAssertThrowsError(
            try shallowParser.parse(data, messageID: 11, includeHTML: false)
        ) { e in
            guard case MailBladeError.decodeFailure = e else {
                return XCTFail("expected decodeFailure")
            }
        }
    }

    // MARK: - parseContentType helper

    func testParseContentTypeStripsQuotesAndExtractsParams() {
        let (mediaType, params) = EMLXParser.parseContentType(
            "multipart/mixed; boundary=\"abc-123\"; charset=utf-8"
        )
        XCTAssertEqual(mediaType, "multipart/mixed")
        XCTAssertEqual(params["boundary"], "abc-123")
        XCTAssertEqual(params["charset"], "utf-8")
    }

    func testParseContentTypeHandlesNoParams() {
        let (mediaType, params) = EMLXParser.parseContentType("text/plain")
        XCTAssertEqual(mediaType, "text/plain")
        XCTAssertTrue(params.isEmpty)
    }

    // MARK: - RFC2047 unit-level

    func testRFC2047QDecode() {
        let s = "=?utf-8?Q?Caf=C3=A9?="
        XCTAssertEqual(RFC2047.decode(s), "Café")
    }

    func testRFC2047BDecode() {
        let s = "=?utf-8?B?VGVzdA==?="
        XCTAssertEqual(RFC2047.decode(s), "Test")
    }

    func testRFC2047PassthroughForNonEncoded() {
        let s = "Plain ASCII subject"
        XCTAssertEqual(RFC2047.decode(s), "Plain ASCII subject")
    }

    func testRFC2047HandlesMixedContent() {
        let s = "Re: =?utf-8?Q?Caf=C3=A9?= meeting tomorrow"
        XCTAssertEqual(RFC2047.decode(s), "Re: Café meeting tomorrow")
    }
}
