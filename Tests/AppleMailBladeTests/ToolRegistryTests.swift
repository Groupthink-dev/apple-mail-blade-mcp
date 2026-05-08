import MCP
import XCTest

@testable import AppleMailBlade

/// Tests for `AppleMailToolRegistry` — the public façade that StallariKit
/// calls into at Phase A.4 onwards. These verify the surface stays at 11
/// tools (9 v0.1 mail tools + DD-256 §A.4 `apple_mail_index_status` and
/// `apple_mail_reindex`), every tool name dispatches to a handler (live
/// or stubbed), and unknown tool names degrade gracefully rather than
/// throwing.
final class ToolRegistryTests: XCTestCase {

    var storePath: String!
    var registry: AppleMailToolRegistry!

    override func setUp() async throws {
        let (config, path) = try SampleEnvelopeBuilder.makeSampleConfig()
        self.storePath = path
        self.registry = try await AppleMailToolRegistry(config: config)
    }

    override func tearDown() async throws {
        if let storePath = storePath {
            SampleEnvelopeBuilder.cleanup(path: storePath)
        }
        registry = nil
        storePath = nil
    }

    // MARK: - Surface

    func testRegistryExposesExactlyElevenTools() async throws {
        let tools = registry.tools()
        XCTAssertEqual(tools.count, 11, "expected 11 tools, got \(tools.count)")
    }

    func testRegistryToolNamesMatchSchemaDeclarations() async throws {
        let names = Set(registry.tools().map { $0.name })
        let expected: Set<String> = [
            "apple_mail_list_accounts",
            "apple_mail_list_mailboxes",
            "apple_mail_list_messages",
            "apple_mail_search_messages",
            "apple_mail_head",
            "apple_mail_read_message",
            "apple_mail_read_attachment",
            "apple_mail_read_thread",
            "apple_mail_extract_entities",
            "apple_mail_index_status",
            "apple_mail_reindex",
        ]
        XCTAssertEqual(names, expected)
    }

    func testRegistryToolsAreNonisolated() {
        // tools() is `nonisolated` — call it without await to confirm the
        // declaration is correct. Compile-time check effectively.
        let _: [Tool] = registry.tools()
    }

    // MARK: - Dispatch

    func testListAccountsDispatchesToHandler() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_list_accounts",
            arguments: nil
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("\"accounts\""))
        XCTAssertFalse(json.contains("\"unknown tool\""))
    }

    func testListMailboxesDispatchesToHandler() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_list_mailboxes",
            arguments: nil
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("\"mailboxes\""))
    }

    func testListMessagesDispatchesToHandler() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_list_messages",
            arguments: ["mailbox_id": .int(1)]
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("\"messages\""))
    }

    func testSearchMessagesDispatchesToHandler() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_search_messages",
            arguments: ["query": .string("status")]
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("\"results\""))
    }

    func testHeadDispatchesToHandler() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_head",
            arguments: ["message_id": .int(1)]
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("\"id\":1"))
    }

    func testReadMessageDispatchesToHandler() async throws {
        // No .emlx file exists in this fixture — handler should surface
        // emlx_not_found, NOT not_implemented.
        let result = await registry.handleCall(
            name: "apple_mail_read_message",
            arguments: ["message_id": .int(1)]
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("\"emlx_not_found\""))
        XCTAssertFalse(json.contains("\"not_implemented\""))
    }

    func testReadAttachmentDispatchesToHandler() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_read_attachment",
            arguments: ["message_id": .int(1), "attachment_id": .int(0)]
        )
        let json = extractText(from: result)
        // No on-disk Attachments tree — handler reports either
        // emlx_not_found (no .emlx → no Attachments dir) or internal_error.
        XCTAssertFalse(json.contains("\"not_implemented\""))
    }

    func testReadThreadDispatchesToHandler() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_read_thread",
            arguments: ["message_id": .int(1)]
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("\"thread\""))
        XCTAssertFalse(json.contains("\"not_implemented\""))
    }

    func testExtractEntitiesDispatchesToHandler() async throws {
        // No .emlx file → handler surfaces emlx_not_found, not not_implemented.
        let result = await registry.handleCall(
            name: "apple_mail_extract_entities",
            arguments: ["message_id": .int(1)]
        )
        let json = extractText(from: result)
        XCTAssertFalse(json.contains("\"not_implemented\""))
    }

    func testUnknownToolNameReturnsInternalError() async throws {
        let result = await registry.handleCall(
            name: "apple_mail_does_not_exist",
            arguments: nil
        )
        let json = extractText(from: result)
        XCTAssertTrue(json.contains("\"internal_error\""))
        XCTAssertTrue(json.contains("unknown tool"))
    }

    // MARK: - No notImplemented anywhere

    /// Regression guard: no tool should route to `not_implemented` at A.4.
    /// Phase A.5 may temporarily reintroduce a stub if a new tool is added,
    /// but the v0.1.0-rc1 surface ships without any `not_implemented` paths.
    func testNoToolRoutesToNotImplemented() async throws {
        for tool in registry.tools() {
            let result = await registry.handleCall(name: tool.name, arguments: nil)
            let json = extractText(from: result)
            XCTAssertFalse(
                json.contains("\"not_implemented\""),
                "tool \(tool.name) routed to not_implemented"
            )
        }
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
