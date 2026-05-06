import XCTest

@testable import AppleMailBlade

final class MailStoreReadTests: XCTestCase {

    var storePath: String!
    var store: MailStore!

    override func setUp() async throws {
        let (config, path) = try SampleEnvelopeBuilder.makeSampleConfig()
        self.storePath = path
        self.store = try MailStore(config: config)
    }

    override func tearDown() async throws {
        if let storePath = storePath {
            SampleEnvelopeBuilder.cleanup(path: storePath)
        }
        store = nil
        storePath = nil
    }

    // MARK: - listAccounts

    func testListAccountsDerivesTwoAccountsFromMailboxURLs() async throws {
        let accounts = try await store.listAccounts()
        XCTAssertEqual(accounts.count, 2)
        let keys = accounts.map { $0.accountKey }.sorted()
        XCTAssertEqual(
            keys,
            [
                "imap://piers%40mm.st@imap.fastmail.com",
                "local://localmac",
            ])
    }

    func testListAccountsAssignsStableSortedIDs() async throws {
        let accounts = try await store.listAccounts()
        let sortedByKey = accounts.sorted { $0.accountKey < $1.accountKey }
        // IDs should match the sorted order: 1 → imap, 2 → local.
        XCTAssertEqual(sortedByKey[0].accountKey, "imap://piers%40mm.st@imap.fastmail.com")
        XCTAssertEqual(sortedByKey[0].id, 1)
        XCTAssertEqual(sortedByKey[1].accountKey, "local://localmac")
        XCTAssertEqual(sortedByKey[1].id, 2)
    }

    func testListAccountsReportsMailboxCounts() async throws {
        let accounts = try await store.listAccounts()
        let imapAccount = accounts.first { $0.accountKey.hasPrefix("imap://") }
        let localAccount = accounts.first { $0.accountKey.hasPrefix("local://") }
        XCTAssertEqual(imapAccount?.mailboxCount, 2)  // INBOX + Archive
        XCTAssertEqual(localAccount?.mailboxCount, 1)  // Old Stuff
    }

    // MARK: - listMailboxes

    func testListMailboxesReturnsAllThree() async throws {
        let mailboxes = try await store.listMailboxes()
        XCTAssertEqual(mailboxes.count, 3)
    }

    func testListMailboxesFiltersByAccountID() async throws {
        let imapBoxes = try await store.listMailboxes(accountID: 1)
        XCTAssertEqual(imapBoxes.count, 2)
        XCTAssertTrue(imapBoxes.allSatisfy { $0.accountID == 1 })

        let localBoxes = try await store.listMailboxes(accountID: 2)
        XCTAssertEqual(localBoxes.count, 1)
        XCTAssertEqual(localBoxes.first?.name, "Old Stuff")  // percent-decoded
    }

    func testListMailboxesUnknownAccountIDReturnsEmpty() async throws {
        let mailboxes = try await store.listMailboxes(accountID: 999)
        XCTAssertEqual(mailboxes.count, 0)
    }

    func testListMailboxesPercentDecodesNames() async throws {
        let mailboxes = try await store.listMailboxes()
        let names = mailboxes.map { $0.name }
        XCTAssertTrue(names.contains("INBOX"))
        XCTAssertTrue(names.contains("Archive"))
        XCTAssertTrue(names.contains("Old Stuff"))
    }

    func testListMailboxesCarriesCounts() async throws {
        let mailboxes = try await store.listMailboxes()
        let inbox = mailboxes.first { $0.name == "INBOX" }
        XCTAssertEqual(inbox?.totalCount, 5)
        XCTAssertEqual(inbox?.unreadCount, 1)
    }

    // MARK: - listMessages

    func testListMessagesReturnsFiveInINBOX() async throws {
        let messages = try await store.listMessages(mailboxID: 1)
        XCTAssertEqual(messages.count, 5)
    }

    func testListMessagesSortsNewestFirst() async throws {
        let messages = try await store.listMessages(mailboxID: 1)
        // msg5 (1717545660) is newest, msg1 (1717200060) is oldest.
        XCTAssertEqual(messages.first?.id, 5)
        XCTAssertEqual(messages.last?.id, 1)
    }

    func testListMessagesIndexOnlyReturnsSubjectFromAndSnippet() async throws {
        let messages = try await store.listMessages(mailboxID: 1)
        let project = messages.first { $0.id == 1 }
        XCTAssertEqual(project?.subject, "Project status update")
        XCTAssertEqual(project?.from, "alice@example.com")
        XCTAssertNotNil(project?.snippet)
    }

    func testListMessagesExposesToRecipients() async throws {
        let messages = try await store.listMessages(mailboxID: 1)
        let invoice = messages.first { $0.id == 4 }
        // msg4 To: piers (cc bob — should NOT appear in `to`).
        XCTAssertEqual(invoice?.to, ["piers@mm.st"])
    }

    func testListMessagesAttachmentFlagFromBitfield() async throws {
        let messages = try await store.listMessages(mailboxID: 1)
        let invoice = messages.first { $0.id == 4 }
        // msg4 has flags bit 6 (64) set — should report hasAttachments=true.
        XCTAssertEqual(invoice?.hasAttachments, true)
        let project = messages.first { $0.id == 1 }
        XCTAssertEqual(project?.hasAttachments, false)
    }

    func testListMessagesReadFlagIsBoolean() async throws {
        let messages = try await store.listMessages(mailboxID: 1)
        let lunch = messages.first { $0.id == 3 }
        XCTAssertEqual(lunch?.isRead, false)
        let project = messages.first { $0.id == 1 }
        XCTAssertEqual(project?.isRead, true)
    }

    func testListMessagesFlaggedFromBoolean() async throws {
        let messages = try await store.listMessages(mailboxID: 1)
        let lunch = messages.first { $0.id == 3 }
        XCTAssertEqual(lunch?.isFlagged, true)
    }

    func testListMessagesHonoursLimit() async throws {
        let messages = try await store.listMessages(mailboxID: 1, limit: 2)
        XCTAssertEqual(messages.count, 2)
    }

    func testListMessagesHonoursOffset() async throws {
        let all = try await store.listMessages(mailboxID: 1, limit: 10, offset: 0)
        let skipFirst = try await store.listMessages(mailboxID: 1, limit: 10, offset: 1)
        XCTAssertEqual(all.count - 1, skipFirst.count)
        XCTAssertEqual(all.dropFirst().map { $0.id }, skipFirst.map { $0.id })
    }

    func testListMessagesClampsLimitToHardCap() async throws {
        let messages = try await store.listMessages(mailboxID: 1, limit: 100_000)
        XCTAssertEqual(messages.count, 5)  // Only 5 messages in INBOX
    }

    func testListMessagesSinceFilterDropsOlder() async throws {
        // Cutoff between msg1 (1717200060) and msg2 (1717286460).
        let cutoff = Date(timeIntervalSince1970: 1_717_250_000)
        let messages = try await store.listMessages(mailboxID: 1, since: cutoff)
        XCTAssertEqual(messages.count, 4)  // msg2..msg5
        XCTAssertFalse(messages.contains { $0.id == 1 })
    }

    func testListMessagesUntilFilterDropsNewer() async throws {
        // Upper bound between msg1 and msg2.
        let until = Date(timeIntervalSince1970: 1_717_250_000)
        let messages = try await store.listMessages(mailboxID: 1, until: until)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.id, 1)
    }

    // MARK: - searchMessages

    func testSearchMessagesFindsBySubjectSubstring() async throws {
        let results = try await store.searchMessages(query: "status update")
        XCTAssertEqual(results.count, 2)  // msg1 + msg2 (Re: ...)
    }

    func testSearchMessagesFindsBySummarySubstring() async throws {
        let results = try await store.searchMessages(query: "Tasmania")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, 6)  // msg6 summary mentions Tasmania
    }

    func testSearchMessagesScopedByMailbox() async throws {
        let inboxResults = try await store.searchMessages(query: "Project", mailboxID: 1)
        XCTAssertEqual(inboxResults.count, 2)
        let archiveResults = try await store.searchMessages(query: "Project", mailboxID: 2)
        XCTAssertEqual(archiveResults.count, 0)
    }

    func testSearchMessagesScopedByAccount() async throws {
        let imapAcctResults = try await store.searchMessages(query: "Pre-Fastmail", accountID: 1)
        XCTAssertEqual(imapAcctResults.count, 0)  // msg8 lives in local account

        let localAcctResults = try await store.searchMessages(query: "Pre-Fastmail", accountID: 2)
        XCTAssertEqual(localAcctResults.count, 1)
        XCTAssertEqual(localAcctResults.first?.id, 8)
    }

    func testSearchMessagesEmptyQueryWouldFailHandlerLevel() async throws {
        // Store-level search with empty query is technically valid (matches all).
        // The handler-level guard rejects empty query before reaching the store.
        // Here we just confirm the store doesn't crash on empty.
        let results = try await store.searchMessages(query: "")
        XCTAssertEqual(results.count, 8)  // Empty LIKE pattern matches all messages
    }

    func testSearchMessagesClampsLimit() async throws {
        let results = try await store.searchMessages(query: "", limit: 100_000)
        XCTAssertEqual(results.count, 8)
    }

    // MARK: - head

    func testHeadReturnsMessageMetadata() async throws {
        let head = try await store.head(messageID: 1)
        XCTAssertEqual(head.id, 1)
        XCTAssertEqual(head.subject, "Project status update")
        XCTAssertEqual(head.from, "alice@example.com")
        XCTAssertEqual(head.isRead, true)
    }

    func testHeadReportsInReplyTo() async throws {
        let head = try await store.head(messageID: 2)
        XCTAssertEqual(head.inReplyTo, "<msg1@example.com>")
        let head1 = try await store.head(messageID: 1)
        XCTAssertNil(head1.inReplyTo)
    }

    func testHeadReportsAttachmentPresence() async throws {
        let head = try await store.head(messageID: 4)
        XCTAssertEqual(head.hasAttachments, true)
    }

    func testHeadUnknownIDThrowsMessageNotFound() async {
        do {
            _ = try await store.head(messageID: 9999)
            XCTFail("expected messageNotFound")
        } catch let error as MailBladeError {
            guard case .messageNotFound(let id) = error else {
                return XCTFail("expected messageNotFound, got \(error)")
            }
            XCTAssertEqual(id, 9999)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
