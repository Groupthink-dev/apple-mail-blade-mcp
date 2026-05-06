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

    /// Minimal V10-shaped schema. Real Apple schema has many more columns;
    /// we only declare what the queries we actually run touch.
    private static func createSchema(_ db: Connection) throws {
        try db.run(
            """
            CREATE TABLE messages (
                ROWID INTEGER PRIMARY KEY,
                message_id TEXT,
                document_id TEXT,
                in_reply_to TEXT,
                remote_id TEXT,
                sender INTEGER,
                subject_prefix TEXT,
                subject INTEGER,
                date_sent REAL,
                date_received REAL,
                date_last_viewed REAL,
                mailbox INTEGER,
                original_mailbox INTEGER,
                flags INTEGER DEFAULT 0,
                read INTEGER DEFAULT 0,
                flagged INTEGER DEFAULT 0,
                deleted INTEGER DEFAULT 0,
                size INTEGER,
                conversation_id INTEGER,
                summary INTEGER,
                color INTEGER,
                encoding INTEGER
            );
            """)
        try db.run(
            """
            CREATE TABLE mailboxes (
                ROWID INTEGER PRIMARY KEY,
                url TEXT,
                total_count INTEGER DEFAULT 0,
                unread_count INTEGER DEFAULT 0,
                unseen_count INTEGER DEFAULT 0,
                change_identifier TEXT
            );
            """)
        try db.run(
            """
            CREATE TABLE addresses (
                ROWID INTEGER PRIMARY KEY,
                address TEXT,
                comment TEXT
            );
            """)
        try db.run(
            """
            CREATE TABLE subjects (
                ROWID INTEGER PRIMARY KEY,
                subject TEXT,
                normalized_subject TEXT
            );
            """)
        try db.run(
            """
            CREATE TABLE recipients (
                ROWID INTEGER PRIMARY KEY,
                message INTEGER,
                address INTEGER,
                type INTEGER,
                position INTEGER
            );
            """)
        try db.run(
            """
            CREATE TABLE summaries (
                ROWID INTEGER PRIMARY KEY,
                summary TEXT
            );
            """)
    }

    /// Sample fixture: 2 accounts derived from URL prefixes (Fastmail IMAP +
    /// On-My-Mac), 3 mailboxes, 8 messages, recipients, subjects, summaries.
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

        // Subjects
        try db.run(
            """
            INSERT INTO subjects (ROWID, subject, normalized_subject) VALUES
                (1, 'Project status update', 'Project status update'),
                (2, 'Re: Project status update', 'Project status update'),
                (3, 'Lunch this week?', 'Lunch this week?'),
                (4, 'Invoice #12345', 'Invoice #12345'),
                (5, 'Newsletter — May edition', 'Newsletter — May edition'),
                (6, 'Vacation photos', 'Vacation photos'),
                (7, 'Old archived item', 'Old archived item'),
                (8, 'Pre-Fastmail correspondence', 'Pre-Fastmail correspondence');
            """)

        // Addresses
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

        // Messages — 5 in INBOX, 2 in Archive, 1 in On-My-Mac
        // Date format: Unix epoch seconds. Use fixed values for deterministic ordering.
        // 1717200000 = 2024-06-01, 1717286400 = 2024-06-02, etc.
        try db.run(
            """
            INSERT INTO messages (
                ROWID, message_id, in_reply_to, sender, subject,
                date_sent, date_received, mailbox, flags, read, flagged, deleted, size,
                conversation_id, summary
            ) VALUES
                (1, '<msg1@example.com>', NULL, 2, 1, 1717200000, 1717200060, 1, 0, 1, 0, 0, 1024, 100, 1),
                (2, '<msg2@example.com>', '<msg1@example.com>', 1, 2, 1717286400, 1717286460, 1, 0, 1, 0, 0, 1100, 100, 2),
                (3, '<msg3@example.com>', NULL, 3, 3, 1717372800, 1717372860, 1, 0, 0, 1, 0, 800, 101, 3),
                (4, '<msg4@example.com>', NULL, 4, 4, 1717459200, 1717459260, 1, 64, 1, 0, 0, 4096, 102, 4),
                (5, '<msg5@example.com>', NULL, 5, 5, 1717545600, 1717545660, 1, 0, 0, 0, 0, 8192, 103, 5),
                (6, '<msg6@example.com>', NULL, 2, 6, 1715000000, 1715000060, 2, 64, 1, 0, 0, 16384, 104, 6),
                (7, '<msg7@example.com>', NULL, 3, 7, 1530000000, 1530000060, 2, 0, 1, 0, 0, 512, 105, 7),
                (8, '<msg8@example.com>', NULL, 6, 8, 1500000000, 1500000060, 3, 0, 1, 0, 0, 768, 106, 8);
            """)

        // Recipients (type 0 = to, 1 = cc, 2 = bcc)
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
