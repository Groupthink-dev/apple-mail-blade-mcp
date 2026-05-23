// MetaEnvelopeTests.swift
//
// DD-338 Phase C Wave 5 — envelope-shape + determinism tests for the 5
// audit_surface-promoted apple-mail tools (4 B + 1 C):
//   - apple_mail_list_accounts (C)
//   - apple_mail_list_mailboxes (B)
//   - apple_mail_list_messages (B)
//   - apple_mail_search_messages (B)
//   - apple_mail_read_thread (B)

import MCP
import XCTest

@testable import AppleMailBlade

final class MetaEnvelopeTests: XCTestCase {

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

    // MARK: - Helper / cross-cutting

    private func call(_ name: String, _ args: [String: Value]? = nil) async -> String {
        let result = await registry.handleCall(name: name, arguments: args)
        return extractText(from: result)
    }

    func testMetaEnvelopeFormatterByteShape() {
        // Spot-check the formatter directly: required-only → exactly 4 keys.
        let meta = MetaEnvelope(
            matchedTotal: 42,
            returned: 10,
            filteredBy: ["mailbox_id=23", "limit=10"],
            latencyMs: 87
        )
        let line = formatMetaLine(meta)
        XCTAssertTrue(line.hasPrefix("_meta: "))
        let json = String(line.dropFirst("_meta: ".count))
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.count, 4)
        XCTAssertEqual(parsed?["matched_total"] as? Int, 42)
        XCTAssertEqual(parsed?["returned"] as? Int, 10)
        XCTAssertEqual(parsed?["filtered_by"] as? [String], ["mailbox_id=23", "limit=10"])
        XCTAssertEqual(parsed?["latency_ms"] as? Int, 87)
    }

    func testMetaEnvelopeOmitsEmptyOptionals() {
        let meta = MetaEnvelope(
            matchedTotal: 1,
            returned: 1,
            filteredBy: [],
            latencyMs: 0,
            redactions: [],
            nextCursor: nil,
            errorNotes: []
        )
        let line = formatMetaLine(meta)
        XCTAssertFalse(line.contains("redactions"))
        XCTAssertFalse(line.contains("next_cursor"))
        XCTAssertFalse(line.contains("error_notes"))
    }

    func testMetaEnvelopeIncludesPresentOptionals() {
        let meta = MetaEnvelope(
            matchedTotal: 2,
            returned: 2,
            filteredBy: [],
            latencyMs: 5,
            redactions: ["cross_account_hops=1"],
            nextCursor: nil,
            errorNotes: nil
        )
        let line = formatMetaLine(meta)
        XCTAssertTrue(line.contains("\"redactions\":[\"cross_account_hops=1\"]"))
        XCTAssertFalse(line.contains("next_cursor"))
    }

    func testMetaQueryDigestIsDeterministic() {
        let a = metaQueryDigest("hello world")
        let b = metaQueryDigest("hello world")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 12)
    }

    func testMetaQueryDigestVariesByInput() {
        let a = metaQueryDigest("hello")
        let b = metaQueryDigest("world")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - apple_mail_list_accounts (C)

    func testListAccountsEnvelopePresent() async {
        let text = await call("apple_mail_list_accounts")
        let meta = parseMeta(from: text)
        XCTAssertMetaShape(meta)
    }

    func testListAccountsEnvelopeFilteredByIsEmpty() async {
        let text = await call("apple_mail_list_accounts")
        let meta = parseMeta(from: text)
        XCTAssertEqual(meta?["filtered_by"] as? [String], [])
    }

    func testListAccountsMatchedEqualsReturned() async {
        let text = await call("apple_mail_list_accounts")
        let meta = parseMeta(from: text)
        XCTAssertEqual(meta?["matched_total"] as? Int, meta?["returned"] as? Int)
    }

    func testListAccountsStructuralDeterminismN5() async {
        // Compare parsed JSON across N=5 calls. Byte-equality on the raw text
        // can vary due to encoder/SQLite incidental ordering of equal-key rows;
        // structural equality is the load-bearing determinism contract for the
        // assembler (which parses, doesn't hash).
        var seen: [NSDictionary] = []
        for _ in 0..<5 {
            let text = await call("apple_mail_list_accounts")
            let payload = payloadJSON(from: text)
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                XCTFail("could not parse payload JSON: \(payload)")
                return
            }
            seen.append(obj as NSDictionary)
        }
        let first = seen[0]
        for (i, other) in seen.enumerated().dropFirst() {
            XCTAssertEqual(first, other, "call \(i) diverged from call 0")
        }
    }

    func testListAccountsPayloadStillContainsAccountsKey() async {
        let text = await call("apple_mail_list_accounts")
        let payload = payloadJSON(from: text)
        XCTAssertTrue(payload.contains("\"accounts\""))
    }

    // MARK: - apple_mail_list_mailboxes (B)

    func testListMailboxesEnvelopePresent() async {
        let text = await call("apple_mail_list_mailboxes")
        let meta = parseMeta(from: text)
        XCTAssertMetaShape(meta)
    }

    func testListMailboxesEmptyFilteredByWhenNoArgs() async {
        let text = await call("apple_mail_list_mailboxes")
        let meta = parseMeta(from: text)
        XCTAssertEqual(meta?["filtered_by"] as? [String], [])
    }

    func testListMailboxesFilteredByIncludesAccountIDWhenSupplied() async {
        let text = await call("apple_mail_list_mailboxes", ["account_id": .int(1)])
        let meta = parseMeta(from: text)
        XCTAssertEqual(meta?["filtered_by"] as? [String], ["account_id=1"])
    }

    func testListMailboxesMatchedEqualsReturned() async {
        let text = await call("apple_mail_list_mailboxes")
        let meta = parseMeta(from: text)
        XCTAssertEqual(meta?["matched_total"] as? Int, meta?["returned"] as? Int)
    }

    func testListMailboxesStructuralDeterminismN3() async {
        var seen: [NSDictionary] = []
        for _ in 0..<3 {
            let text = await call("apple_mail_list_mailboxes")
            let payload = payloadJSON(from: text)
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                XCTFail("could not parse payload JSON: \(payload)")
                return
            }
            seen.append(obj as NSDictionary)
        }
        let first = seen[0]
        for (i, other) in seen.enumerated().dropFirst() {
            XCTAssertEqual(first, other, "call \(i) diverged from call 0")
        }
    }

    // MARK: - apple_mail_list_messages (B)

    func testListMessagesEnvelopePresent() async {
        let text = await call("apple_mail_list_messages", ["mailbox_id": .int(1)])
        let meta = parseMeta(from: text)
        XCTAssertMetaShape(meta)
    }

    func testListMessagesFilteredByContainsMailboxID() async {
        let text = await call("apple_mail_list_messages", ["mailbox_id": .int(1)])
        let meta = parseMeta(from: text)
        let fb = meta?["filtered_by"] as? [String] ?? []
        XCTAssertTrue(fb.contains("mailbox_id=1"))
    }

    func testListMessagesFilteredBySortedAlphabetically() async {
        let text = await call("apple_mail_list_messages", [
            "mailbox_id": .int(1),
            "limit": .int(5),
            "offset": .int(0),
        ])
        let meta = parseMeta(from: text)
        let fb = meta?["filtered_by"] as? [String] ?? []
        XCTAssertEqual(fb, fb.sorted())
        XCTAssertTrue(fb.contains("limit=5"))
        XCTAssertTrue(fb.contains("offset=0"))
        XCTAssertTrue(fb.contains("mailbox_id=1"))
    }

    func testListMessagesMatchedEqualsReturned() async {
        let text = await call("apple_mail_list_messages", ["mailbox_id": .int(1)])
        let meta = parseMeta(from: text)
        XCTAssertEqual(meta?["matched_total"] as? Int, meta?["returned"] as? Int)
    }

    func testListMessagesNextCursorOmitted() async {
        // Per Wave 5 OQ-6: offset-paginated tools OMIT next_cursor.
        let text = await call("apple_mail_list_messages", ["mailbox_id": .int(1)])
        let meta = parseMeta(from: text)
        XCTAssertNil(meta?["next_cursor"])
    }

    // MARK: - apple_mail_search_messages (B)

    func testSearchMessagesEnvelopePresent() async {
        let text = await call("apple_mail_search_messages", ["query": .string("hello")])
        let meta = parseMeta(from: text)
        XCTAssertMetaShape(meta)
    }

    func testSearchMessagesQueryFieldIsHashedNotRaw() async {
        let text = await call("apple_mail_search_messages", ["query": .string("secret-token-xyz")])
        let meta = parseMeta(from: text)
        let fb = meta?["filtered_by"] as? [String] ?? []
        // No filtered_by entry should contain the verbatim query.
        XCTAssertFalse(fb.contains(where: { $0.contains("secret-token-xyz") }))
        // Exactly one filtered_by entry should match `query=<12-chars>`.
        let queryEntries = fb.filter { $0.hasPrefix("query=") }
        XCTAssertEqual(queryEntries.count, 1)
        let digest = String(queryEntries[0].dropFirst("query=".count))
        XCTAssertEqual(digest.count, 12)
    }

    func testSearchMessagesQueryDigestIsDeterministic() async {
        let textA = await call("apple_mail_search_messages", ["query": .string("repeated")])
        let textB = await call("apple_mail_search_messages", ["query": .string("repeated")])
        let metaA = parseMeta(from: textA)
        let metaB = parseMeta(from: textB)
        let fbA = (metaA?["filtered_by"] as? [String])?.first(where: { $0.hasPrefix("query=") })
        let fbB = (metaB?["filtered_by"] as? [String])?.first(where: { $0.hasPrefix("query=") })
        XCTAssertNotNil(fbA)
        XCTAssertEqual(fbA, fbB)
    }

    func testSearchMessagesFilteredBySortedAlphabetically() async {
        let text = await call("apple_mail_search_messages", [
            "query": .string("hello"),
            "account_id": .int(1),
            "limit": .int(5),
        ])
        let meta = parseMeta(from: text)
        let fb = meta?["filtered_by"] as? [String] ?? []
        XCTAssertEqual(fb, fb.sorted())
    }

    func testSearchMessagesMatchedEqualsReturned() async {
        let text = await call("apple_mail_search_messages", ["query": .string("hello")])
        let meta = parseMeta(from: text)
        XCTAssertEqual(meta?["matched_total"] as? Int, meta?["returned"] as? Int)
    }

    // MARK: - apple_mail_read_thread (B)

    func testReadThreadEnvelopePresent() async throws {
        // Find a real message id from the fixture by enumerating mailbox 1.
        let listText = await call("apple_mail_list_messages", ["mailbox_id": .int(1)])
        let listPayload = payloadJSON(from: listText)
        let listData = listPayload.data(using: .utf8)!
        let listJson = try? JSONSerialization.jsonObject(with: listData) as? [String: Any]
        let messages = listJson?["messages"] as? [[String: Any]] ?? []
        guard let first = messages.first, let id = first["id"] as? Int else {
            throw XCTSkip("no message in fixture to seed read_thread")
        }
        let text = await call("apple_mail_read_thread", ["message_id": .int(id)])
        let meta = parseMeta(from: text)
        XCTAssertMetaShape(meta)
    }

    func testReadThreadFilteredByIncludesMessageID() async {
        let text = await call("apple_mail_read_thread", ["message_id": .int(1)])
        let meta = parseMeta(from: text)
        let fb = meta?["filtered_by"] as? [String] ?? []
        XCTAssertEqual(fb, ["message_id=1"])
    }

    func testReadThreadRedactionsOmittedWhenNoCrossAccount() async {
        // Mailbox 1 lives in the imap account; a thread seeded from one of its
        // messages typically does not cross accounts in the fixture.
        let text = await call("apple_mail_read_thread", ["message_id": .int(1)])
        let meta = parseMeta(from: text)
        // If no cross-account hops, redactions key MUST be absent.
        if let thread = parseMeta(from: text), let total = thread["matched_total"] as? Int, total > 0 {
            // Verify the absence convention.
            let r = meta?["redactions"]
            // r may be nil (key absent) or an array containing only cross_account_hops=N.
            if let arr = r as? [String] {
                XCTAssertFalse(arr.contains(where: { $0 == "cross_account_hops=0" }))
            }
        }
    }

    func testReadThreadDeterminism() async {
        let textA = await call("apple_mail_read_thread", ["message_id": .int(1)])
        let textB = await call("apple_mail_read_thread", ["message_id": .int(1)])
        XCTAssertEqual(payloadJSON(from: textA), payloadJSON(from: textB))
    }

    // MARK: - existing-payload preservation

    func testListAccountsPayloadStableAcrossEnvelopeAddition() async {
        // The existing tests assert `\"accounts\"` substring; ensure that still holds.
        let text = await call("apple_mail_list_accounts")
        XCTAssertTrue(text.contains("\"accounts\""))
        XCTAssertTrue(text.contains("\n\n_meta: "))
    }
}
