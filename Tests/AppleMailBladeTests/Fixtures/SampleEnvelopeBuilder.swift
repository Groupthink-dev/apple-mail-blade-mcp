import Foundation
import SQLite

@testable import AppleMailBlade

/// Builder that materialises a synthetic Apple Mail Envelope Index on disk
/// under the tmp directory. Tests get a fully-populated minimal V10 schema
/// with sample accounts (derived from mailbox URLs), mailboxes, messages,
/// addresses, subjects, recipients, and summaries — plus a config that
/// points at it.
///
/// Why not `:memory:`? — `Connection(":memory:", readonly: true)` is
/// contradictory; SQLite's read-only mode requires a real file. We
/// materialise to a temp file (under `/private/tmp/`) and clean up in
/// tearDown.
enum SampleEnvelopeBuilder {

    /// Build a fresh sample store at a temp path. Returns the absolute path.
    /// Caller is responsible for deleting the directory when done.
    static func makeSampleStore() throws -> String {
        let dir = "/private/tmp/apple-mail-blade-tests-\(UUID().uuidString)/V10/MailData"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/Envelope Index"

        // Open writable to create + populate, then close. The actor under
        // test will reopen read-only.
        let db = try Connection(path)
        try createSchema(db)
        try insertSampleData(db)
        try db.run("PRAGMA wal_checkpoint(TRUNCATE);")
        return path
    }

    /// Build a config pointing at a fresh sample store.
    static func makeSampleConfig() throws -> (config: MailBladeConfig, path: String) {
        let path = try makeSampleStore()
        let config = try MailBladeConfig(storePath: path, maxResultsHardCap: 1000)
        return (config, path)
    }

    /// Minimal V10-shaped schema.
    ///
    /// **Aligned with real macOS V10 schema as of 2026-05-07.** Earlier
    /// fixtures encoded community-published schema docs that disagreed
    /// with the actual `Envelope Index` on macOS 14/15/16+ in three ways:
    ///   1. `messages.in_reply_to` doesn't exist; In-Reply-To lives in
    ///      the `message_references` junction table.
    ///   2. `messages.message_id` is INTEGER (a hash/FK), not TEXT.
    ///      RFC822 Message-ID *strings* live in
    ///      `message_global_data.message_id_header`.
    ///   3. `addresses` is *not* directly FK from `messages.sender`.
    ///      Real path: `messages.sender → senders.ROWID →
    ///      sender_addresses.sender → addresses.ROWID`.
    ///
    /// We only declare columns the blade's queries actually touch. Real
    /// Apple schema has many more (~30 cols on `messages`, ~80 indexes
    /// across the DB) — see `Tests/AppleMailBladeTests/Fixtures/real-v10-schema.sql`
    /// for the full reference dump.
    private static func createSchema(_ db: Connection) throws {
        // Senders + the 3-way join chain to address text.
        try db.run(
            """
            CREATE TABLE senders (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                contact_identifier TEXT,
                bucket INTEGER NOT NULL DEFAULT 0,
                user_initiated INTEGER NOT NULL DEFAULT 1,
                UNIQUE(contact_identifier) ON CONFLICT ABORT
            );
            """)
        try db.run(
            """
            CREATE TABLE addresses (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                address TEXT NOT NULL,
                comment TEXT NOT NULL,
                UNIQUE(address, comment) ON CONFLICT ABORT
            );
            """)
        try db.run(
            """
            CREATE TABLE sender_addresses (
                address INTEGER PRIMARY KEY,
                sender INTEGER NOT NULL REFERENCES senders(ROWID) ON DELETE CASCADE
            );
            """)

        // Subjects + summaries — simple lookup tables.
        try db.run(
            """
            CREATE TABLE subjects (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                subject TEXT NOT NULL
            );
            """)
        try db.run(
            """
            CREATE TABLE summaries (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                summary TEXT NOT NULL
            );
            """)

        // Mailboxes — real schema has more columns; we declare only those
        // the blade queries (plus NOT NULL ones to avoid INSERT failures).
        try db.run(
            """
            CREATE TABLE mailboxes (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL,
                total_count INTEGER NOT NULL DEFAULT 0,
                unread_count INTEGER NOT NULL DEFAULT 0,
                deleted_count INTEGER NOT NULL DEFAULT 0,
                unseen_count INTEGER NOT NULL DEFAULT 0,
                unread_count_adjusted_for_duplicates INTEGER NOT NULL DEFAULT 0
            );
            """)

        // Messages — real V10 column set, scoped to what the blade reads.
        // Note: in_reply_to is NOT a column. global_message_id NOT NULL.
        try db.run(
            """
            CREATE TABLE messages (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id INTEGER NOT NULL DEFAULT 0,
                global_message_id INTEGER NOT NULL,
                sender INTEGER,
                subject INTEGER NOT NULL,
                summary INTEGER,
                date_sent INTEGER,
                date_received INTEGER,
                mailbox INTEGER NOT NULL,
                flags INTEGER NOT NULL DEFAULT 0,
                read INTEGER NOT NULL DEFAULT 0,
                flagged INTEGER NOT NULL DEFAULT 0,
                deleted INTEGER NOT NULL DEFAULT 0,
                size INTEGER NOT NULL DEFAULT 0,
                conversation_id INTEGER NOT NULL DEFAULT 0
            );
            """)

        // message_global_data — where the RFC822 Message-ID *string* lives.
        try db.run(
            """
            CREATE TABLE message_global_data (
                ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id INTEGER,
                message_id_header TEXT,
                UNIQUE(message_id) ON CONFLICT ABORT
            );
            """)

        // message_references — In-Reply-To / References chain. `is_originator`
        // == 1 marks the immediate parent; older ancestors have 0.
        try db.run(
            """
            CREATE TABLE message_references (
                ROWID INTEGER PRIMARY KEY,
                message INTEGER NOT NULL REFERENCES messages(ROWID) ON DELETE CASCADE,
                reference INTEGER NOT NULL DEFAULT 0,
                is_originator INTEGER NOT NULL DEFAULT 0
            );
            """)

        // Recipients — same shape as published docs.
        try db.run(
            """
            CREATE TABLE recipients (
                ROWID INTEGER PRIMARY KEY,
                message INTEGER NOT NULL,
                address INTEGER NOT NULL,
                type INTEGER,
                position INTEGER
            );
            """)
    }

    /// Sample fixture: 2 accounts derived from URL prefixes (Fastmail IMAP +
    /// On-My-Mac), 3 mailboxes, 8 messages, recipients, subjects, summaries.
    /// Real V10 schema requires three new tables to be populated:
    /// `senders`, `sender_addresses`, `message_global_data`, plus
    /// `message_references` for In-Reply-To.
    /// Use fixed Unix epoch dates so tests are deterministic.
    private static func insertSampleData(_ db: Connection) throws {

        // Mailboxes
        // Account 1: imap://piers%40mm.st@imap.fastmail.com
        // Account 2: local://localmac
        try db.run(
            """
            INSERT INTO mailboxes (ROWID, url, total_count, unread_count, unseen_count) VALUES
                (1, 'imap://piers%40mm.st@imap.fastmail.com/INBOX', 5, 1, 1),
                (2, 'imap://piers%40mm.st@imap.fastmail.com/Archive', 2, 0, 0),
                (3, 'local://localmac/On%20My%20Mac/Old%20Stuff', 1, 0, 0);
            """)

        // Subjects (no normalized_subject in real V10).
        try db.run(
            """
            INSERT INTO subjects (ROWID, subject) VALUES
                (1, 'Project status update'),
                (2, 'Re: Project status update'),
                (3, 'Lunch this week?'),
                (4, 'Invoice #12345'),
                (5, 'Newsletter — May edition'),
                (6, 'Vacation photos'),
                (7, 'Old archived item'),
                (8, 'Pre-Fastmail correspondence');
            """)

        // Addresses — both columns NOT NULL in real V10.
        try db.run(
            """
            INSERT INTO addresses (ROWID, address, comment) VALUES
                (1, 'piers@mm.st', 'Piers Lawrence'),
                (2, 'alice@example.com', 'Alice Smith'),
                (3, 'bob@example.com', 'Bob Jones'),
                (4, 'billing@vendor.example', 'Vendor Billing'),
                (5, 'newsletter@news.example', 'News Daily'),
                (6, 'old-friend@oldhost.example', 'Old Friend');
            """)

        // Senders — one per address in this fixture (real V10 may have
        // many addresses per sender for the same contact).
        try db.run(
            """
            INSERT INTO senders (ROWID, contact_identifier) VALUES
                (1, 'piers'),
                (2, 'alice'),
                (3, 'bob'),
                (4, 'billing'),
                (5, 'newsletter'),
                (6, 'old-friend');
            """)

        // sender_addresses — address-PK join. Each address row maps to
        // exactly one sender; one sender can own multiple addresses.
        try db.run(
            """
            INSERT INTO sender_addresses (address, sender) VALUES
                (1, 1),
                (2, 2),
                (3, 3),
                (4, 4),
                (5, 5),
                (6, 6);
            """)

        // Summaries
        try db.run(
            """
            INSERT INTO summaries (ROWID, summary) VALUES
                (1, 'Quick update on the Q2 milestones, ahead of schedule.'),
                (2, 'Reply with revised dates for the launch.'),
                (3, 'Thursday or Friday work?'),
                (4, 'Total $1,234.56 due May 31st.'),
                (5, 'This month: 5 articles on Apple silicon performance.'),
                (6, 'Photos from Tasmania trip — see attachments.'),
                (7, 'Historical record from 2018 archive.'),
                (8, 'From before consolidating to Fastmail in 2020.');
            """)

        // message_global_data — 1:1 with messages in this fixture; the
        // RFC822 Message-ID header strings live here. ROWID is what
        // messages.global_message_id references.
        try db.run(
            """
            INSERT INTO message_global_data (ROWID, message_id, message_id_header) VALUES
                (1, 1, '<msg1@example.com>'),
                (2, 2, '<msg2@example.com>'),
                (3, 3, '<msg3@example.com>'),
                (4, 4, '<msg4@example.com>'),
                (5, 5, '<msg5@example.com>'),
                (6, 6, '<msg6@example.com>'),
                (7, 7, '<msg7@example.com>'),
                (8, 8, '<msg8@example.com>');
            """)

        // Messages — 5 in INBOX, 2 in Archive, 1 in On-My-Mac.
        // sender column FKs to senders.ROWID (not addresses).
        // Date format: Unix epoch seconds (INTEGER in real V10).
        // 1717200000 = 2024-06-01, 1717286400 = 2024-06-02, etc.
        try db.run(
            """
            INSERT INTO messages (
                ROWID, message_id, global_message_id, sender, subject,
                date_sent, date_received, mailbox, flags, read, flagged,
                deleted, size, conversation_id, summary
            ) VALUES
                (1, 1, 1, 2, 1, 1717200000, 1717200060, 1, 0, 1, 0, 0, 1024, 100, 1),
                (2, 2, 2, 1, 2, 1717286400, 1717286460, 1, 0, 1, 0, 0, 1100, 100, 2),
                (3, 3, 3, 3, 3, 1717372800, 1717372860, 1, 0, 0, 1, 0, 800, 101, 3),
                (4, 4, 4, 4, 4, 1717459200, 1717459260, 1, 64, 1, 0, 0, 4096, 102, 4),
                (5, 5, 5, 5, 5, 1717545600, 1717545660, 1, 0, 0, 0, 0, 8192, 103, 5),
                (6, 6, 6, 2, 6, 1715000000, 1715000060, 2, 64, 1, 0, 0, 16384, 104, 6),
                (7, 7, 7, 3, 7, 1530000000, 1530000060, 2, 0, 1, 0, 0, 512, 105, 7),
                (8, 8, 8, 6, 8, 1500000000, 1500000060, 3, 0, 1, 0, 0, 768, 106, 8);
            """)

        // message_references — msg2 is a reply to msg1.
        // is_originator=1 marks the immediate parent.
        try db.run(
            """
            INSERT INTO message_references (message, reference, is_originator) VALUES
                (2, 1, 1);
            """)

        // Recipients (type 0 = to, 1 = cc, 2 = bcc).
        // msg1 To: piers; msg2 To: alice; msg3 To: piers; msg4 To: piers + cc bob;
        // msg5 To: piers; msg6 To: alice + bob; msg7 To: piers; msg8 To: piers
        try db.run(
            """
            INSERT INTO recipients (message, address, type, position) VALUES
                (1, 1, 0, 0),
                (2, 2, 0, 0),
                (3, 1, 0, 0),
                (4, 1, 0, 0),
                (4, 3, 1, 1),
                (5, 1, 0, 0),
                (6, 2, 0, 0),
                (6, 3, 0, 1),
                (7, 1, 0, 0),
                (8, 1, 0, 0);
            """)
    }

    static func cleanup(path: String) {
        // Path is .../V10/MailData/Envelope Index — walk up to the tmp UUID dir.
        let mailDataDir = (path as NSString).deletingLastPathComponent
        let v10Dir = (mailDataDir as NSString).deletingLastPathComponent
        let testRoot = (v10Dir as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: testRoot)
    }
}
