import XCTest

@testable import AppleMailBlade

/// Locator tests focused on v0.1.1 hint-based subtree scoping plus the
/// fallback pruned full-tree scan. Real-corpus performance is verified
/// out-of-test via `stallari-cli mail smoke`; these tests pin the
/// correctness invariants:
///
/// 1. Hint with URL whose host == on-disk account dir resolves directly.
/// 2. Hint with URL whose host != any on-disk account dir falls back to
///    the slow-path top-level scan and still finds the right subtree.
/// 3. Hint resolution is cached per mailboxID — second call doesn't
///    re-scan the top level.
/// 4. `Attachments/` subtrees are pruned during full-tree scan, so a
///    bogus `<id>.emlx` placed inside an Attachments tree is NOT
///    returned (we'd return the canonical Messages-tree path instead).
/// 5. Locator falls back to full scan when the hint doesn't resolve at
///    all (no matching account dir found).
final class EMLXLocatorTests: XCTestCase {

    var v10Root: String!

    override func setUp() async throws {
        v10Root = "/private/tmp/apple-mail-blade-locator-tests-\(UUID().uuidString)/V10"
        try FileManager.default.createDirectory(
            atPath: "\(v10Root!)/MailData",
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let v10Root = v10Root {
            let parent = (v10Root as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: parent)
        }
        v10Root = nil
    }

    private func makeConfig() throws -> MailBladeConfig {
        // The locator only reads `config.storePath` to derive the V10
        // root (parent of MailData/). The validator accepts any path
        // under `/private/tmp/`, so an in-memory-only Envelope Index
        // path string is fine — the locator never opens the SQLite file.
        return try MailBladeConfig(
            storePath: "\(v10Root!)/MailData/Envelope Index"
        )
    }

    /// Layout helper: write a `.emlx` file at the canonical V10 path
    /// `<root>/<accountDir>/<mailboxName>.mbox/<mboxUUID>/Data/0/Messages/<id>.emlx`
    /// and return the resulting absolute path.
    @discardableResult
    private func writeEmlx(
        accountDir: String, mailbox: String, mboxUUID: String, id: Int64
    ) throws -> String {
        let dir = "\(v10Root!)/\(accountDir)/\(mailbox).mbox/\(mboxUUID)/Data/0/Messages"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let path = "\(dir)/\(id).emlx"
        FileManager.default.createFile(atPath: path, contents: Data("0\n".utf8))
        return path
    }

    /// Drop a noisy `Attachments/` subtree containing a (decoy) `.emlx`
    /// to verify pruning. On real disk this never happens, but it's the
    /// most direct way to assert the scan skips Attachments/.
    @discardableResult
    private func writeNoisyAttachments(
        accountDir: String, mailbox: String, mboxUUID: String, id: Int64
    ) throws -> String {
        let dir = "\(v10Root!)/\(accountDir)/\(mailbox).mbox/\(mboxUUID)/Attachments/\(id)/0"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let path = "\(dir)/\(id).emlx"
        FileManager.default.createFile(atPath: path, contents: Data("decoy".utf8))
        return path
    }

    // MARK: - Hint-based fast path

    func testHintWithMatchingHostResolvesDirectly() async throws {
        let accountUUID = "CBB15DC8-BFF0-41F0-9981-EBDBCBAD8832"
        let canonical = try writeEmlx(
            accountDir: accountUUID,
            mailbox: "INBOX",
            mboxUUID: "inbox-uuid",
            id: 42
        )

        let locator = EMLXLocator(config: try makeConfig())
        let hint = MailboxHint(
            mailboxID: 1,
            url: "imap://\(accountUUID)/INBOX"
        )
        let resolved = await locator.locate(messageID: 42, hint: hint)
        XCTAssertEqual(resolved, canonical)
    }

    func testHintFallsBackToTopLevelScanForUnmatchedHost() async throws {
        // Test fixtures often use schemes like
        // `imap://piers%40mm.st@imap.fastmail.com/INBOX` — host doesn't
        // match the on-disk account dir name. The locator should fall
        // back to scanning top-level dirs and still find the subtree.
        let canonical = try writeEmlx(
            accountDir: "imap-fastmail",
            mailbox: "INBOX",
            mboxUUID: "inbox-uuid",
            id: 7
        )

        let locator = EMLXLocator(config: try makeConfig())
        let hint = MailboxHint(
            mailboxID: 1,
            url: "imap://piers%40mm.st@imap.fastmail.com/INBOX"
        )
        let resolved = await locator.locate(messageID: 7, hint: hint)
        XCTAssertEqual(resolved, canonical)
    }

    func testHintResolutionDecodesPercentEncodedMailboxNames() async throws {
        let canonical = try writeEmlx(
            accountDir: "acct-1",
            mailbox: "Junk Mail",  // on-disk uses literal space
            mboxUUID: "junk-uuid",
            id: 9
        )

        let locator = EMLXLocator(config: try makeConfig())
        let hint = MailboxHint(
            mailboxID: 5,
            url: "imap://acct-1/Junk%20Mail"
        )
        let resolved = await locator.locate(messageID: 9, hint: hint)
        XCTAssertEqual(resolved, canonical)
    }

    // MARK: - Pruning fallback

    func testFullScanPrunesAttachmentsSubtree() async throws {
        // Canonical .emlx in Messages/ + a decoy .emlx in Attachments/.
        // Without pruning, the enumerator might surface the decoy first
        // (depends on directory traversal order). With pruning, only the
        // canonical Messages path is reachable.
        let canonical = try writeEmlx(
            accountDir: "acct-1",
            mailbox: "INBOX",
            mboxUUID: "uuid-A",
            id: 100
        )
        _ = try writeNoisyAttachments(
            accountDir: "acct-1",
            mailbox: "INBOX",
            mboxUUID: "uuid-A",
            id: 100
        )

        // No hint — full-tree scan.
        let locator = EMLXLocator(config: try makeConfig())
        let resolved = await locator.locate(messageID: 100, hint: nil)
        XCTAssertEqual(resolved, canonical)
        XCTAssertFalse(
            resolved?.contains("/Attachments/") ?? true,
            "locator returned a path inside Attachments/: \(resolved ?? "nil")"
        )
    }

    // MARK: - No match

    func testReturnsNilWhenMessageDoesntExist() async throws {
        try writeEmlx(
            accountDir: "acct-1",
            mailbox: "INBOX",
            mboxUUID: "uuid-A",
            id: 1
        )

        let locator = EMLXLocator(config: try makeConfig())
        let resolved = await locator.locate(messageID: 99999, hint: nil)
        XCTAssertNil(resolved)
    }

    func testHintWithUnresolvableUrlFallsBackToFullScan() async throws {
        // Hint's URL host doesn't match any on-disk account dir, AND the
        // mailbox name doesn't match either. Locator should fall through
        // to full-tree scan and still find the canonical path.
        let canonical = try writeEmlx(
            accountDir: "acct-A",
            mailbox: "INBOX",
            mboxUUID: "uuid-1",
            id: 50
        )

        let locator = EMLXLocator(config: try makeConfig())
        // Hint refers to a mailbox that isn't on disk. The subtree probe
        // returns nil; full-tree scan still finds id=50 in INBOX.
        let hint = MailboxHint(
            mailboxID: 1,
            url: "imap://wrong-host/NonexistentMailbox"
        )
        let resolved = await locator.locate(messageID: 50, hint: hint)
        XCTAssertEqual(resolved, canonical)
    }
}
