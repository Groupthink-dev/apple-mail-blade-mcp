// MetaEnvelopeTests.swift
//
// DD-338 Phase C Wave 5 — envelope-shape + determinism tests for the 5
// audit_surface-promoted apple-mail tools (4 B + 1 C):
//   - apple_mail_list_accounts (C)
//   - apple_mail_list_mailboxes (B)
//   - apple_mail_list_messages (B)
//   - apple_mail_search_messages (B)
//   - apple_mail_read_thread (B)
//
// Post-DD-338-Phase-C-Wave-5 cutover: envelope construction + formatting now
// flow through the canonical `MCPHelpers` SPM dep
// (https://github.com/Groupthink-dev/stallari-mcp-helpers-swift). Canonical
// wire-shape vs. the hand-rolled v1 differs in two ways exercised by these
// tests:
//   - `redactions` ALWAYS emitted (defaults to `[]`); was omitted when empty
//   - `next_cursor` ALWAYS emitted (JSON `null` when nil); was omitted when nil
//   - `filtered_by` alphabetically sorted by the formatter (caller no longer
//     needs to pre-sort; existing pre-sort calls remain harmless)
//   - `formatMetaLine` now throws (encoding-failure surface; unreachable in
//     practice for our value types)

import MCP
import MCPHelpers
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

    func testMetaEnvelopeFormatterByteShape() throws {
        // Canonical MCPHelpers shape: ALWAYS emits matched_total, returned,
        // filtered_by, latency_ms, redactions, next_cursor (6 required keys).
        // error_notes omitted when nil/empty. `filtered_by` sorted alphabetically.
        let meta = MetaEnvelope(
            matchedTotal: 42,
            returned: 10,
            latencyMs: 87,
            filteredBy: ["mailbox_id=23", "limit=10"]
        )
        let line = try formatMetaLine(meta)
        XCTAssertTrue(line.hasPrefix("_meta: "))
        let json = String(line.dropFirst("_meta: ".count))
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.count, 6)
        XCTAssertEqual(parsed?["matched_total"] as? Int, 42)
        XCTAssertEqual(parsed?["returned"] as? Int, 10)
        // Canonical sorts filtered_by; ["limit=10", "mailbox_id=23"] (alphabetical).
        XCTAssertEqual(parsed?["filtered_by"] as? [String], ["limit=10", "mailbox_id=23"])
        XCTAssertEqual(parsed?["latency_ms"] as? Int, 87)
        XCTAssertEqual(parsed?["redactions"] as? [String], [])
        // next_cursor: JSON `null` -> NSNull on parse.
        XCTAssertTrue(parsed?["next_cursor"] is NSNull)
    }

    func testMetaEnvelopeAlwaysEmitsRedactionsAndNextCursor() throws {
        // Canonical contract: redactions + next_cursor are REQUIRED fields.
        // Empty redactions → `[]`; nil next_cursor → JSON `null`. error_notes
        // alone is the omit-when-empty optional.
        let meta = MetaEnvelope(
            matchedTotal: 1,
            returned: 1,
            latencyMs: 0,
            filteredBy: [],
            redactions: [],
            nextCursor: nil,
            errorNotes: []
        )
        let line = try formatMetaLine(meta)
        XCTAssertTrue(line.contains("\"redactions\":[]"))
        XCTAssertTrue(line.contains("\"next_cursor\":null"))
        XCTAssertFalse(line.contains("error_notes"))
    }

    func testMetaEnvelopeIncludesPresentRedactions() throws {
        let meta = MetaEnvelope(
            matchedTotal: 2,
            returned: 2,
            latencyMs: 5,
            filteredBy: [],
            redactions: ["cross_account_hops=1"],
            nextCursor: nil,
            errorNotes: nil
        )
        let line = try formatMetaLine(meta)
        XCTAssertTrue(line.contains("\"redactions\":[\"cross_account_hops=1\"]"))
        XCTAssertTrue(line.contains("\"next_cursor\":null"))
    }

    func testMetaEnvelopeFilteredBySortedByFormatter() throws {
        // Canonical formatter sorts filteredBy alphabetically — caller order
        // is no longer load-bearing. Tools may still pre-sort for clarity;
        // outcome is identical.
        let meta = MetaEnvelope(
            matchedTotal: 0,
            returned: 0,
            latencyMs: 0,
            filteredBy: ["z=1", "a=2", "m=3"]
        )
        let line = try formatMetaLine(meta)
        XCTAssertTrue(line.contains("\"filtered_by\":[\"a=2\",\"m=3\",\"z=1\"]"))
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

    func testListMessagesNextCursorAlwaysPresentAsNull() async {
        // Per canonical MCPHelpers contract: next_cursor is REQUIRED; offset-
        // paginated tools emit JSON `null`. Was omit-when-nil in hand-rolled v1
        // (DD-338 W5 OQ-6) — canonical promotes to always-present.
        let text = await call("apple_mail_list_messages", ["mailbox_id": .int(1)])
        let meta = parseMeta(from: text)
        XCTAssertNotNil(meta)
        XCTAssertTrue(meta?["next_cursor"] is NSNull)
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

    func testReadThreadRedactionsAlwaysPresent() async {
        // Per canonical MCPHelpers contract: redactions is REQUIRED. When no
        // cross-account hops, the array is empty (`[]`). Was omit-when-empty
        // in hand-rolled v1 — canonical promotes to always-present.
        let text = await call("apple_mail_read_thread", ["message_id": .int(1)])
        let meta = parseMeta(from: text)
        XCTAssertNotNil(meta?["redactions"])
        let r = meta?["redactions"] as? [String]
        XCTAssertNotNil(r)
        // No "cross_account_hops=0" entry — only positive counts surface.
        if let arr = r {
            XCTAssertFalse(arr.contains(where: { $0 == "cross_account_hops=0" }))
        }
    }

    func testReadThreadDeterminism() async throws {
        // Structural equality (parsed dict compare) rather than string equality —
        // the underlying handler's payload encoder doesn't use `.sortedKeys`
        // (only the MetaEnvelope helper does, per Precedent #3). Foundation
        // Dictionary iteration is non-deterministic on macos-15 CI runners but
        // happens to be stable locally; assembler parses JSON not byte-hashes
        // it, so structural equality is the load-bearing determinism property.
        let textA = await call("apple_mail_read_thread", ["message_id": .int(1)])
        let textB = await call("apple_mail_read_thread", ["message_id": .int(1)])
        let dataA = try XCTUnwrap(payloadJSON(from: textA).data(using: .utf8))
        let dataB = try XCTUnwrap(payloadJSON(from: textB).data(using: .utf8))
        let dictA = try JSONSerialization.jsonObject(with: dataA) as? NSDictionary
        let dictB = try JSONSerialization.jsonObject(with: dataB) as? NSDictionary
        XCTAssertEqual(dictA, dictB)
    }

    // MARK: - existing-payload preservation

    func testListAccountsPayloadStableAcrossEnvelopeAddition() async {
        // The existing tests assert `\"accounts\"` substring; ensure that still holds.
        let text = await call("apple_mail_list_accounts")
        XCTAssertTrue(text.contains("\"accounts\""))
        XCTAssertTrue(text.contains("\n\n_meta: "))
    }

    // MARK: - canonical-shape gate (DD-338 W5 acceptance criterion)

    func testFormatMetaLineEmitsCanonicalMCPHelpersShape() throws {
        // Gate against future drift between this blade's emission and the
        // canonical MCPHelpers wire shape. The canonical input/output pair
        // mirrors the MCPHelpers Swift v0.1.0 own test fixture: required
        // fields populated, optional errorNotes omitted, filtered_by sorted.
        let meta = MetaEnvelope(
            matchedTotal: 100,
            returned: 25,
            latencyMs: 12,
            filteredBy: ["b=2", "a=1"],
            redactions: [],
            nextCursor: nil,
            errorNotes: nil
        )
        let line = try formatMetaLine(meta)
        XCTAssertEqual(
            line,
            #"_meta: {"matched_total":100,"returned":25,"filtered_by":["a=1","b=2"],"latency_ms":12,"redactions":[],"next_cursor":null}"#
        )
    }
}
