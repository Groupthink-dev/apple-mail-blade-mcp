import MCP
import XCTest

@testable import AppleMailBlade

/// Integration tests for `ReadMessageHandler` — exercises the full path
/// from registry init → MailStore.head → EMLXLocator scan → EMLXParser
/// → JSON result. Uses fixtures that pair the synthetic Envelope Index
/// with on-disk `.emlx` files under the same V10 root.
final class ReadMessageTests: XCTestCase {

    var storePath: String!
    var registry: AppleMailToolRegistry!

    override func setUp() async throws {
        let (config, path) = try SampleEnvelopeBuilder.makeSampleConfig()
        self.storePath = path
        // Write .emlx files under the V10 root for messages 1, 2, and 6.
        // Locator walks <V10>/.../<msgID>.emlx so any sub-tree works.
        let v10Root = (((path as NSString).deletingLastPathComponent) as NSString)
            .deletingLastPathComponent
        let mboxRoot = "\(v10Root)/imap-fastmail/INBOX.mbox/inbox-uuid"
        try FileManager.default.createDirectory(
            atPath: "\(mboxRoot)/Data/0/Messages",
            withIntermediateDirectories: true
        )
        // Message 1 — text/plain
        _ = try SampleEMLXBuilder.writeEMLX(
            SampleEMLXBuilder.textPlain,
            atPath: "\(mboxRoot)/Data/0/Messages/1.emlx"
        )
        // Message 2 — reply
        _ = try SampleEMLXBuilder.writeEMLX(
            SampleEMLXBuilder.replyMessage,
            atPath: "\(mboxRoot)/Data/0/Messages/2.emlx"
        )
        // Message 6 — multipart/mixed with attachment in Archive.mbox
        let archiveMbox = "\(v10Root)/imap-fastmail/Archive.mbox/archive-uuid"
        try FileManager.default.createDirectory(
            atPath: "\(archiveMbox)/Data/0/Messages",
            withIntermediateDirectories: true
        )
        _ = try SampleEMLXBuilder.writeEMLX(
            SampleEMLXBuilder.multipartMixedWithAttachment,
            atPath: "\(archiveMbox)/Data/0/Messages/6.emlx"
        )
        // Drop a fake attachment into the mbox Attachments tree.
        let attachBytes = "Hello world - this is not really a JPEG"
            .data(using: .utf8)!
        _ = try SampleEMLXBuilder.writeAttachment(
            bytes: attachBytes,
            filename: "cradle-mountain.jpg",
            messageID: 6,
            partIndex: 0,
            mboxRoot: archiveMbox
        )
        self.registry = try AppleMailToolRegistry(config: config)
    }

    override func tearDown() async throws {
        if let storePath = storePath {
            SampleEnvelopeBuilder.cleanup(path: storePath)
        }
        registry = nil
        storePath = nil
    }

    func testReadMessageReturnsParsedBody() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_read_message",
            arguments: ["message_id": .int(1)]
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("ahead of schedule"), "body text missing: \(json)")
        XCTAssertTrue(json.contains("Project status update"))
        XCTAssertFalse(json.contains("\"isError\":true"))
    }

    func testReadMessageReturnsAttachmentMetaForMultipartMixed() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_read_message",
            arguments: ["message_id": .int(6)]
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("cradle-mountain.jpg"), "attachment filename missing")
        // JSON encoder escapes forward slashes — match the escaped form.
        XCTAssertTrue(
            json.contains("image\\/jpeg") || json.contains("image/jpeg"),
            "mime type missing — got: \(json.prefix(500))"
        )
        XCTAssertTrue(json.contains("Tasmania"), "body text missing")
    }

    func testReadMessageHTMLNotIncludedByDefault() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_read_message",
            arguments: ["message_id": .int(1)]
        )
        let json = extractText(from: result)
        // Default JSON encoder may omit nil-valued keys OR include "bodyHTML":null.
        // Both shapes signal "no HTML returned"; assert by absence of an HTML
        // payload string rather than a specific null encoding.
        XCTAssertFalse(json.contains("<html>"))
        XCTAssertFalse(json.contains("<body>"))
        XCTAssertFalse(json.contains("<p>"))
    }

    func testReadMessageMissingFileSurfacesEMLXNotFound() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_read_message",
            arguments: ["message_id": .int(3)]  // No .emlx written for msg 3
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("\"emlx_not_found\""))
    }

    func testReadMessageUnknownIDSurfacesMessageNotFound() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_read_message",
            arguments: ["message_id": .int(9999)]
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("\"message_not_found\""))
    }

    func testReadMessageMissingArgumentSurfacesInternalError() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_read_message",
            arguments: [:]
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("missing or non-integer message_id"))
    }

    // MARK: - read_attachment

    func testReadAttachmentReturnsBytes() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_read_attachment",
            arguments: ["message_id": .int(6), "attachment_id": .int(0)]
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("\"filename\":\"cradle-mountain.jpg\""))
        XCTAssertTrue(json.contains("\"bytesBase64\":"))
    }

    func testReadAttachmentMissingPartSurfacesError() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_read_attachment",
            arguments: ["message_id": .int(6), "attachment_id": .int(99)]
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("\"internal_error\""))
    }

    // MARK: - read_thread

    func testReadThreadReturnsBothMessagesViaConversationID() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_read_thread",
            arguments: ["message_id": .int(1)]
        )
        let json = extractText(from: result)
        // msg1 + msg2 share conversation_id=100 in the fixture.
        XCTAssertTrue(json.contains("Project status update"))
        XCTAssertTrue(json.contains("Re: Project status update"))
    }

    func testReadThreadReturnsLoneMessage() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_read_thread",
            arguments: ["message_id": .int(3)]  // conversation_id=101, only msg
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("Lunch this week?"))
    }

    // MARK: - extract_entities (still notImplemented in A.2)

    func testExtractEntitiesRoutesToNotImplemented() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_extract_entities",
            arguments: ["message_id": .int(1)]
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("\"not_implemented\""))
    }

    // MARK: - helper

    private func extractText(from result: CallTool.Result) -> String {
        var out = ""
        for item in result.content {
            if case .text(let text, _, _) = item {
                out += text
            }
        }
        return out
    }
}
