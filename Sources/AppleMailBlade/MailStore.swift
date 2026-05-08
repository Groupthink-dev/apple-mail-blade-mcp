import CryptoKit
import Foundation
import SQLite

/// Read-only SQLite reader over Apple Mail's `Envelope Index`.
///
/// Concurrency model: `actor`-isolated. Holds a single `SQLite.Connection`
/// opened in read-only mode with a busy timeout (default 200ms) — Mail.app
/// keeps the database open in WAL mode while it syncs, so brief contention
/// is normal and we wait it out rather than failing.
///
/// Path discipline: never opens anything outside `Config.storePath`. Path
/// validation is enforced by `MailBladeConfig.validate(storePath:)` at
/// config-construction time; this actor trusts the validated config.
///
/// The actor surface is index-only in v0.1.0 Phase A.1 — it does NOT touch
/// `.emlx` files. That work lands in Phase A.2.
public actor MailStore {

    public let config: MailBladeConfig
    private let connection: Connection

    /// Optional FTS5 query client for fast `apple_mail_search_messages`
    /// routing (DD-256 §A.4). Nil in standalone-blade tests; the harness
    /// wires a real impl post-construction. When non-nil and healthy,
    /// `searchMessages` flips to the FTS5 path; otherwise falls through
    /// to the LIKE path (`searchMessagesLIKE`) — same result shape, ~30×
    /// slower on a 100k-message corpus.
    private var fts5Client: (any MailFTS5QueryClient)?

    /// Wire (or unwire) the FTS5 query client. Called by the harness
    /// once `local-corpus-index.db` is open and the Mail blade adapter
    /// has registered with `IndexCoordinator`.
    public func setFTS5QueryClient(_ client: (any MailFTS5QueryClient)?) {
        self.fts5Client = client
    }

    /// Open the underlying SQLite database read-only.
    public init(config: MailBladeConfig) throws {
        self.config = config

        // Existence check — gives a cleaner error than letting SQLite stumble.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: config.storePath, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else {
            throw MailBladeError.storeMissing(path: config.storePath)
        }

        do {
            self.connection = try Connection(config.storePath, readonly: true)
        } catch let error as Result {
            throw Self.translate(sqliteError: error, path: config.storePath)
        } catch {
            throw MailBladeError.internalError(
                "Connection init: \(String(describing: error))"
            )
        }

        connection.busyTimeout = Double(config.sqliteBusyTimeoutMs) / 1000.0
    }

    // MARK: - Read API

    /// List accounts derived from `mailboxes.url` prefixes. v0.1.0 does not
    /// rely on a separate `accounts` table — the URL prefix
    /// `<scheme>://<user>@<host>` is the canonical account identifier and
    /// synthetic Int64 IDs are assigned by deterministic sorted-key order.
    public func listAccounts() throws -> [Account] {
        let mailboxes = try fetchAllMailboxesRaw()
        let groups = groupByAccountKey(mailboxes)
        let sortedKeys = groups.keys.sorted()
        var accounts: [Account] = []
        accounts.reserveCapacity(sortedKeys.count)
        for (offset, key) in sortedKeys.enumerated() {
            let bucket = groups[key] ?? []
            // Display name from the first mailbox in the bucket — they all
            // share the same account-key, so any URL gives the same answer.
            let displayName: String = {
                if let first = bucket.first {
                    return MailSchema.accountDisplayName(fromMailboxURL: first.url)
                }
                return key
            }()
            accounts.append(
                Account(
                    id: Int64(offset + 1),
                    name: displayName,
                    accountKey: key,
                    mailboxCount: bucket.count
                ))
        }
        return accounts
    }

    /// List mailboxes, optionally scoped to a single (synthetic) account ID.
    public func listMailboxes(accountID: Int64? = nil) throws -> [Mailbox] {
        let raw = try fetchAllMailboxesRaw()
        let groups = groupByAccountKey(raw)
        let sortedKeys = groups.keys.sorted()

        // Build a (rowid → synthetic accountID) map.
        var rowIDToAccountID: [Int64: Int64] = [:]
        for (offset, key) in sortedKeys.enumerated() {
            let synthetic = Int64(offset + 1)
            for mb in groups[key] ?? [] {
                rowIDToAccountID[mb.rowID] = synthetic
            }
        }

        let mailboxes: [Mailbox] = raw.compactMap { mb in
            guard let synthetic = rowIDToAccountID[mb.rowID] else { return nil }
            if let filter = accountID, filter != synthetic { return nil }
            return Mailbox(
                id: mb.rowID,
                accountID: synthetic,
                url: mb.url,
                name: mailboxName(from: mb.url),
                totalCount: mb.totalCount,
                unreadCount: mb.unreadCount,
                unseenCount: mb.unseenCount
            )
        }
        return mailboxes.sorted { $0.url < $1.url }
    }

    /// List messages within a mailbox. Index-only — never opens `.emlx`.
    public func listMessages(
        mailboxID: Int64,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) throws -> [MessageSummary] {
        let cappedLimit = min(max(1, limit), config.maxResultsHardCap)
        let cappedOffset = max(0, offset)

        var sql = """
            SELECT m.ROWID,
                   m.mailbox,
                   mgd.message_id_header,
                   m.conversation_id,
                   s.subject,
                   addr.address,
                   m.date_sent,
                   m.date_received,
                   m.read,
                   m.flagged,
                   m.size,
                   summ.summary
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN senders sndr ON sndr.ROWID = m.sender
            LEFT JOIN sender_addresses sa ON sa.sender = sndr.ROWID
            LEFT JOIN addresses addr ON addr.ROWID = sa.address
            LEFT JOIN summaries summ ON summ.ROWID = m.summary
            LEFT JOIN message_global_data mgd ON mgd.ROWID = m.global_message_id
            WHERE m.mailbox = ?
              AND (m.deleted IS NULL OR m.deleted = 0)
            """
        var bindings: [Binding?] = [mailboxID]
        if let since = since {
            sql += "  AND m.date_received >= ?\n"
            bindings.append(since.timeIntervalSince1970)
        }
        if let until = until {
            sql += "  AND m.date_received <= ?\n"
            bindings.append(until.timeIntervalSince1970)
        }
        sql += """
            ORDER BY m.date_received DESC
            LIMIT ? OFFSET ?
            """
        bindings.append(Int64(cappedLimit))
        bindings.append(Int64(cappedOffset))

        let summaries = try runQuery(sql, bindings: bindings) {
            row -> MessageSummary in
            let id = int64(row, 0) ?? 0
            return MessageSummary(
                id: id,
                mailboxID: int64(row, 1) ?? mailboxID,
                messageID: string(row, 2),
                conversationID: int64(row, 3),
                subject: string(row, 4),
                from: string(row, 5),
                to: [],  // Filled below to avoid N queries inside this loop
                dateSent: MailSchema.date(fromUnixEpoch: double(row, 6)),
                dateReceived: MailSchema.date(fromUnixEpoch: double(row, 7)),
                isRead: (int64(row, 8) ?? 0) != 0,
                isFlagged: (int64(row, 9) ?? 0) != 0,
                hasAttachments: false,  // Filled by hasAttachments check below
                snippet: string(row, 11),
                sizeBytes: int64(row, 10).map { Int($0) }
            )
        }
        // Enrich with To-recipients + attachment-presence (single SQL pass each).
        let ids = summaries.map { $0.id }
        let toMap = try fetchToRecipients(messageIDs: ids)
        let attachMap = try fetchAttachmentPresence(messageIDs: ids)
        return summaries.map { s in
            MessageSummary(
                id: s.id,
                mailboxID: s.mailboxID,
                messageID: s.messageID,
                conversationID: s.conversationID,
                subject: s.subject,
                from: s.from,
                to: toMap[s.id] ?? [],
                dateSent: s.dateSent,
                dateReceived: s.dateReceived,
                isRead: s.isRead,
                isFlagged: s.isFlagged,
                hasAttachments: attachMap[s.id] ?? false,
                snippet: s.snippet,
                sizeBytes: s.sizeBytes
            )
        }
    }

    /// Search messages by subject or summary substring. Routes between
    /// the FTS5 sidecar (when healthy) and the LIKE fallback. Result
    /// shape is identical across paths.
    ///
    /// Routing decision (DD-256 §A.4): if a `MailFTS5QueryClient` is
    /// wired AND it reports `isHealthyForQuery == true`, the FTS5 path
    /// is used (~30ms on a 100k-message corpus). Otherwise the LIKE
    /// path runs (~600–2000ms on the same corpus). Standalone-blade
    /// builds always hit the LIKE path.
    public func searchMessages(
        query: String,
        accountID: Int64? = nil,
        mailboxID: Int64? = nil,
        since: Date? = nil,
        limit: Int = 50
    ) async throws -> [MessageSummary] {
        if let client = fts5Client, await client.isHealthyForQuery {
            return try await searchMessagesFTS5(
                query: query,
                accountID: accountID,
                mailboxID: mailboxID,
                since: since,
                limit: limit,
                client: client
            )
        }
        return try searchMessagesLIKE(
            query: query,
            accountID: accountID,
            mailboxID: mailboxID,
            since: since,
            limit: limit
        )
    }

    /// LIKE-based fallback (the v0.1.x implementation, kept verbatim
    /// behind a renamed entry point). Used when no FTS5 client is wired
    /// or when the index is missing / behind / rebuilding.
    public func searchMessagesLIKE(
        query: String,
        accountID: Int64? = nil,
        mailboxID: Int64? = nil,
        since: Date? = nil,
        limit: Int = 50
    ) throws -> [MessageSummary] {
        let cappedLimit = min(max(1, limit), config.maxResultsHardCap)
        let needle = "%\(query)%"

        // For account-scoped search, resolve mailbox IDs in that account first.
        var mailboxIDFilter: [Int64]? = nil
        if let accountID = accountID {
            let mailboxes = try listMailboxes(accountID: accountID)
            mailboxIDFilter = mailboxes.map { $0.id }
            if mailboxIDFilter?.isEmpty == true {
                return []
            }
        }

        var sql = """
            SELECT m.ROWID,
                   m.mailbox,
                   mgd.message_id_header,
                   m.conversation_id,
                   s.subject,
                   addr.address,
                   m.date_sent,
                   m.date_received,
                   m.read,
                   m.flagged,
                   m.size,
                   summ.summary
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN senders sndr ON sndr.ROWID = m.sender
            LEFT JOIN sender_addresses sa ON sa.sender = sndr.ROWID
            LEFT JOIN addresses addr ON addr.ROWID = sa.address
            LEFT JOIN summaries summ ON summ.ROWID = m.summary
            LEFT JOIN message_global_data mgd ON mgd.ROWID = m.global_message_id
            """
        var bindings: [Binding?] = []

        var whereClauses = [
            "(m.deleted IS NULL OR m.deleted = 0)",
            "(s.subject LIKE ? OR summ.summary LIKE ?)",
        ]
        bindings.append(needle)
        bindings.append(needle)

        if let mailboxID = mailboxID {
            whereClauses.append("m.mailbox = ?")
            bindings.append(mailboxID)
        }
        if let mailboxIDFilter = mailboxIDFilter {
            let placeholders = Array(repeating: "?", count: mailboxIDFilter.count).joined(separator: ", ")
            whereClauses.append("m.mailbox IN (\(placeholders))")
            for id in mailboxIDFilter {
                bindings.append(id)
            }
        }
        if let since = since {
            whereClauses.append("m.date_received >= ?")
            bindings.append(since.timeIntervalSince1970)
        }

        sql += "\nWHERE " + whereClauses.joined(separator: "\n  AND ") + "\n"
        sql += """
            ORDER BY m.date_received DESC
            LIMIT ?
            """
        bindings.append(Int64(cappedLimit))

        let summaries = try runQuery(sql, bindings: bindings) {
            row -> MessageSummary in
            return MessageSummary(
                id: int64(row, 0) ?? 0,
                mailboxID: int64(row, 1) ?? 0,
                messageID: string(row, 2),
                conversationID: int64(row, 3),
                subject: string(row, 4),
                from: string(row, 5),
                to: [],
                dateSent: MailSchema.date(fromUnixEpoch: double(row, 6)),
                dateReceived: MailSchema.date(fromUnixEpoch: double(row, 7)),
                isRead: (int64(row, 8) ?? 0) != 0,
                isFlagged: (int64(row, 9) ?? 0) != 0,
                hasAttachments: false,
                snippet: string(row, 11),
                sizeBytes: int64(row, 10).map { Int($0) }
            )
        }
        let ids = summaries.map { $0.id }
        let toMap = try fetchToRecipients(messageIDs: ids)
        let attachMap = try fetchAttachmentPresence(messageIDs: ids)
        return summaries.map { s in
            MessageSummary(
                id: s.id,
                mailboxID: s.mailboxID,
                messageID: s.messageID,
                conversationID: s.conversationID,
                subject: s.subject,
                from: s.from,
                to: toMap[s.id] ?? [],
                dateSent: s.dateSent,
                dateReceived: s.dateReceived,
                isRead: s.isRead,
                isFlagged: s.isFlagged,
                hasAttachments: attachMap[s.id] ?? false,
                snippet: s.snippet,
                sizeBytes: s.sizeBytes
            )
        }
    }

    /// FTS5-backed fast path (DD-256 §A.4). Asks the harness's
    /// `MailFTS5QueryClient` for matching ROWIDs, then SQL-joins back
    /// to the live `messages` table for filters + result shape.
    ///
    /// Same filter set as `searchMessagesLIKE`: deletion, mailbox,
    /// account-derived mailbox set, since. The join-back is
    /// authoritative for deletions (FTS5 may carry stale rows for
    /// recently-deleted messages until the next reindex).
    private func searchMessagesFTS5(
        query: String,
        accountID: Int64?,
        mailboxID: Int64?,
        since: Date?,
        limit: Int,
        client: any MailFTS5QueryClient
    ) async throws -> [MessageSummary] {
        let cappedLimit = min(max(1, limit), config.maxResultsHardCap)
        let rowIDs = try await client.searchFTS5(query: query, limit: cappedLimit)
        if rowIDs.isEmpty { return [] }

        // Resolve account-scoped mailbox set up front, mirroring the
        // LIKE path's logic.
        var mailboxIDFilter: [Int64]? = nil
        if let accountID = accountID {
            let mailboxes = try listMailboxes(accountID: accountID)
            mailboxIDFilter = mailboxes.map { $0.id }
            if mailboxIDFilter?.isEmpty == true {
                return []
            }
        }

        let placeholders = Array(repeating: "?", count: rowIDs.count).joined(separator: ", ")
        var sql = """
            SELECT m.ROWID,
                   m.mailbox,
                   mgd.message_id_header,
                   m.conversation_id,
                   s.subject,
                   addr.address,
                   m.date_sent,
                   m.date_received,
                   m.read,
                   m.flagged,
                   m.size,
                   summ.summary
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN senders sndr ON sndr.ROWID = m.sender
            LEFT JOIN sender_addresses sa ON sa.sender = sndr.ROWID
            LEFT JOIN addresses addr ON addr.ROWID = sa.address
            LEFT JOIN summaries summ ON summ.ROWID = m.summary
            LEFT JOIN message_global_data mgd ON mgd.ROWID = m.global_message_id
            """
        var bindings: [Binding?] = []

        var whereClauses = [
            "(m.deleted IS NULL OR m.deleted = 0)",
            "m.ROWID IN (\(placeholders))",
        ]
        for rowID in rowIDs { bindings.append(rowID) }

        if let mailboxID = mailboxID {
            whereClauses.append("m.mailbox = ?")
            bindings.append(mailboxID)
        }
        if let mailboxIDFilter = mailboxIDFilter {
            let mbPlaceholders = Array(repeating: "?", count: mailboxIDFilter.count).joined(separator: ", ")
            whereClauses.append("m.mailbox IN (\(mbPlaceholders))")
            for id in mailboxIDFilter { bindings.append(id) }
        }
        if let since = since {
            whereClauses.append("m.date_received >= ?")
            bindings.append(since.timeIntervalSince1970)
        }

        sql += "\nWHERE " + whereClauses.joined(separator: "\n  AND ") + "\n"
        sql += """
            ORDER BY m.date_received DESC
            LIMIT ?
            """
        bindings.append(Int64(cappedLimit))

        let summaries = try runQuery(sql, bindings: bindings) {
            row -> MessageSummary in
            MessageSummary(
                id: int64(row, 0) ?? 0,
                mailboxID: int64(row, 1) ?? 0,
                messageID: string(row, 2),
                conversationID: int64(row, 3),
                subject: string(row, 4),
                from: string(row, 5),
                to: [],
                dateSent: MailSchema.date(fromUnixEpoch: double(row, 6)),
                dateReceived: MailSchema.date(fromUnixEpoch: double(row, 7)),
                isRead: (int64(row, 8) ?? 0) != 0,
                isFlagged: (int64(row, 9) ?? 0) != 0,
                hasAttachments: false,
                snippet: string(row, 11),
                sizeBytes: int64(row, 10).map { Int($0) }
            )
        }
        let ids = summaries.map { $0.id }
        let toMap = try fetchToRecipients(messageIDs: ids)
        let attachMap = try fetchAttachmentPresence(messageIDs: ids)
        return summaries.map { s in
            MessageSummary(
                id: s.id,
                mailboxID: s.mailboxID,
                messageID: s.messageID,
                conversationID: s.conversationID,
                subject: s.subject,
                from: s.from,
                to: toMap[s.id] ?? [],
                dateSent: s.dateSent,
                dateReceived: s.dateReceived,
                isRead: s.isRead,
                isFlagged: s.isFlagged,
                hasAttachments: attachMap[s.id] ?? false,
                snippet: s.snippet,
                sizeBytes: s.sizeBytes
            )
        }
    }

    /// Cheap metadata lookup. Reads only the index row — never opens `.emlx`.
    /// `inReplyTo` is derived via a separate query against
    /// `message_references` + `message_global_data` because real V10
    /// doesn't store an in_reply_to column on `messages`.
    public func head(messageID: Int64) throws -> MessageHead {
        let sql = """
            SELECT m.ROWID,
                   m.mailbox,
                   mgd.message_id_header,
                   m.conversation_id,
                   s.subject,
                   addr.address,
                   m.date_sent,
                   m.date_received,
                   m.read,
                   m.flagged,
                   m.size
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN senders sndr ON sndr.ROWID = m.sender
            LEFT JOIN sender_addresses sa ON sa.sender = sndr.ROWID
            LEFT JOIN addresses addr ON addr.ROWID = sa.address
            LEFT JOIN message_global_data mgd ON mgd.ROWID = m.global_message_id
            WHERE m.ROWID = ?
            """
        let rows = try runQuery(sql, bindings: [messageID]) {
            row -> MessageHead in
            return MessageHead(
                id: int64(row, 0) ?? 0,
                mailboxID: int64(row, 1) ?? 0,
                messageID: string(row, 2),
                conversationID: int64(row, 3),
                subject: string(row, 4),
                from: string(row, 5),
                dateSent: MailSchema.date(fromUnixEpoch: double(row, 6)),
                dateReceived: MailSchema.date(fromUnixEpoch: double(row, 7)),
                isRead: (int64(row, 8) ?? 0) != 0,
                isFlagged: (int64(row, 9) ?? 0) != 0,
                hasAttachments: false,
                sizeBytes: int64(row, 10).map { Int($0) },
                inReplyTo: nil  // Filled below via message_references lookup
            )
        }
        guard let head = rows.first else {
            throw MailBladeError.messageNotFound(id: messageID)
        }
        // Single-row attachment-presence lookup.
        let attachMap = try fetchAttachmentPresence(messageIDs: [messageID])
        let inReplyTo = try fetchInReplyTo(messageID: messageID)
        return MessageHead(
            id: head.id,
            mailboxID: head.mailboxID,
            messageID: head.messageID,
            conversationID: head.conversationID,
            subject: head.subject,
            from: head.from,
            dateSent: head.dateSent,
            dateReceived: head.dateReceived,
            isRead: head.isRead,
            isFlagged: head.isFlagged,
            hasAttachments: attachMap[messageID] ?? false,
            sizeBytes: head.sizeBytes,
            inReplyTo: inReplyTo
        )
    }

    /// Resolve `In-Reply-To` for a message by walking
    /// `message_references` (immediate-parent only — `is_originator = 1`)
    /// and looking up the parent's RFC822 `Message-ID` header in
    /// `message_global_data`. Returns `nil` if the message has no parent
    /// or the lookup fails. Real V10 doesn't store this on `messages`.
    private func fetchInReplyTo(messageID: Int64) throws -> String? {
        let sql = """
            SELECT mgd.message_id_header
            FROM message_references mr
            JOIN messages parent ON parent.ROWID = mr.reference
            LEFT JOIN message_global_data mgd ON mgd.ROWID = parent.global_message_id
            WHERE mr.message = ?
              AND mr.is_originator = 1
            LIMIT 1
            """
        let rows = try runQuery(sql, bindings: [messageID]) { row -> String? in
            return self.string(row, 0)
        }
        return rows.first ?? nil
    }

    // MARK: - Thread support (Phase A.2)

    /// Fetch all message heads sharing a `conversation_id`. Returns empty
    /// when the conversation doesn't exist. Excludes deleted messages.
    /// `inReplyTo` left nil per row; consumers requiring it should call
    /// `head(messageID:)` per-message which fills it via
    /// `message_references` lookup.
    public func messageHeadsForConversation(_ conversationID: Int64) throws -> [MessageHead] {
        let sql = """
            SELECT m.ROWID,
                   m.mailbox,
                   mgd.message_id_header,
                   m.conversation_id,
                   s.subject,
                   addr.address,
                   m.date_sent,
                   m.date_received,
                   m.read,
                   m.flagged,
                   m.size
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN senders sndr ON sndr.ROWID = m.sender
            LEFT JOIN sender_addresses sa ON sa.sender = sndr.ROWID
            LEFT JOIN addresses addr ON addr.ROWID = sa.address
            LEFT JOIN message_global_data mgd ON mgd.ROWID = m.global_message_id
            WHERE m.conversation_id = ?
              AND (m.deleted IS NULL OR m.deleted = 0)
            ORDER BY m.date_received ASC, m.ROWID ASC
            """
        let heads = try runQuery(sql, bindings: [conversationID]) {
            row -> MessageHead in
            return MessageHead(
                id: int64(row, 0) ?? 0,
                mailboxID: int64(row, 1) ?? 0,
                messageID: string(row, 2),
                conversationID: int64(row, 3),
                subject: string(row, 4),
                from: string(row, 5),
                dateSent: MailSchema.date(fromUnixEpoch: double(row, 6)),
                dateReceived: MailSchema.date(fromUnixEpoch: double(row, 7)),
                isRead: (int64(row, 8) ?? 0) != 0,
                isFlagged: (int64(row, 9) ?? 0) != 0,
                hasAttachments: false,
                sizeBytes: int64(row, 10).map { Int($0) },
                inReplyTo: nil
            )
        }
        let ids = heads.map { $0.id }
        let attachMap = try fetchAttachmentPresence(messageIDs: ids)
        return heads.map { h in
            MessageHead(
                id: h.id,
                mailboxID: h.mailboxID,
                messageID: h.messageID,
                conversationID: h.conversationID,
                subject: h.subject,
                from: h.from,
                dateSent: h.dateSent,
                dateReceived: h.dateReceived,
                isRead: h.isRead,
                isFlagged: h.isFlagged,
                hasAttachments: attachMap[h.id] ?? false,
                sizeBytes: h.sizeBytes,
                inReplyTo: nil
            )
        }
    }

    /// Look up a message head by its RFC822 `Message-ID` header value.
    /// Returns `nil` when no match is found. Used by `In-Reply-To` /
    /// `References` thread reconstruction in `ThreadResolver`.
    /// Real V10 stores the RFC822 string in
    /// `message_global_data.message_id_header`, NOT
    /// `messages.message_id` (which is an INTEGER hash/FK).
    public func messageHead(forMessageID rfcMessageID: String) throws -> MessageHead? {
        let sql = """
            SELECT m.ROWID,
                   m.mailbox,
                   mgd.message_id_header,
                   m.conversation_id,
                   s.subject,
                   addr.address,
                   m.date_sent,
                   m.date_received,
                   m.read,
                   m.flagged,
                   m.size
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN senders sndr ON sndr.ROWID = m.sender
            LEFT JOIN sender_addresses sa ON sa.sender = sndr.ROWID
            LEFT JOIN addresses addr ON addr.ROWID = sa.address
            JOIN message_global_data mgd ON mgd.ROWID = m.global_message_id
            WHERE mgd.message_id_header = ?
              AND (m.deleted IS NULL OR m.deleted = 0)
            LIMIT 1
            """
        let rows = try runQuery(sql, bindings: [rfcMessageID]) {
            row -> MessageHead in
            return MessageHead(
                id: int64(row, 0) ?? 0,
                mailboxID: int64(row, 1) ?? 0,
                messageID: string(row, 2),
                conversationID: int64(row, 3),
                subject: string(row, 4),
                from: string(row, 5),
                dateSent: MailSchema.date(fromUnixEpoch: double(row, 6)),
                dateReceived: MailSchema.date(fromUnixEpoch: double(row, 7)),
                isRead: (int64(row, 8) ?? 0) != 0,
                isFlagged: (int64(row, 9) ?? 0) != 0,
                hasAttachments: false,
                sizeBytes: int64(row, 10).map { Int($0) },
                inReplyTo: nil
            )
        }
        return rows.first
    }

    /// Resolve the canonical `mailboxes.url` for a given mailbox ROWID.
    /// Single indexed lookup; intended to feed `EMLXLocator.MailboxHint`
    /// so `.emlx` scans can be scoped to one mailbox's on-disk subtree.
    /// Returns `nil` if the mailbox doesn't exist (caller falls back to
    /// the locator's pruned full-tree scan).
    public func mailboxURL(forMailboxID mailboxID: Int64) throws -> String? {
        let sql = "SELECT url FROM mailboxes WHERE ROWID = ? LIMIT 1"
        let rows = try runQuery(sql, bindings: [mailboxID]) { row -> String? in
            return self.string(row, 0)
        }
        return rows.first ?? nil
    }

    // MARK: - Internal helpers

    /// Internal raw mailbox snapshot used for accounts derivation.
    private struct RawMailbox: Sendable {
        let rowID: Int64
        let url: String
        let totalCount: Int
        let unreadCount: Int
        let unseenCount: Int
    }

    private func fetchAllMailboxesRaw() throws -> [RawMailbox] {
        let sql = """
            SELECT ROWID, url, total_count, unread_count, unseen_count
            FROM mailboxes
            ORDER BY ROWID
            """
        return try runQuery(sql, bindings: []) { row in
            RawMailbox(
                rowID: int64(row, 0) ?? 0,
                url: string(row, 1) ?? "",
                totalCount: Int(int64(row, 2) ?? 0),
                unreadCount: Int(int64(row, 3) ?? 0),
                unseenCount: Int(int64(row, 4) ?? 0)
            )
        }
    }

    private func groupByAccountKey(_ mailboxes: [RawMailbox]) -> [String: [RawMailbox]] {
        var groups: [String: [RawMailbox]] = [:]
        for mb in mailboxes {
            let key = MailSchema.accountKey(fromMailboxURL: mb.url)
            groups[key, default: []].append(mb)
        }
        return groups
    }

    /// Best-effort mailbox display name from a URL — last path segment,
    /// percent-decoded, with a fallback to the URL itself.
    private func mailboxName(from url: String) -> String {
        guard !url.isEmpty else { return "(unknown)" }
        if let lastSlash = url.lastIndex(of: "/") {
            let suffix = url[url.index(after: lastSlash)...]
            let raw = String(suffix)
            return raw.removingPercentEncoding ?? raw
        }
        return url
    }

    /// Fetch To-recipients for a batch of message IDs in one SQL pass.
    /// Returns `[messageID: [addressString]]`. Empty for absent messages.
    private func fetchToRecipients(messageIDs: [Int64]) throws -> [Int64: [String]] {
        guard !messageIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
        let sql = """
            SELECT r.message, a.address
            FROM recipients r
            JOIN addresses a ON a.ROWID = r.address
            WHERE r.type = ?
              AND r.message IN (\(placeholders))
            ORDER BY r.message, r.position
            """
        var bindings: [Binding?] = [MailSchema.RecipientType.to]
        for id in messageIDs { bindings.append(id) }
        var result: [Int64: [String]] = [:]
        try runQuery(sql, bindings: bindings) { row -> Void in
            let mid = self.int64(row, 0) ?? 0
            let addr = self.string(row, 1) ?? ""
            if !addr.isEmpty {
                result[mid, default: []].append(addr)
            }
        }
        return result
    }

    /// Cheap "does this message have attachments?" check that doesn't open
    /// `.emlx`. v0.1.0 uses the `messages.flags` bit (Apple sets a flag bit
    /// when MIME walker found an `attachment` disposition during indexing).
    /// Phase A.2 will refine this once `.emlx` parsing lands.
    private func fetchAttachmentPresence(messageIDs: [Int64]) throws -> [Int64: Bool] {
        guard !messageIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
        // flags bit 6 (0x40) is "has attachments" in observed V10 schemas.
        let sql = """
            SELECT ROWID, (CASE WHEN (flags & 64) > 0 THEN 1 ELSE 0 END) AS has_attach
            FROM messages
            WHERE ROWID IN (\(placeholders))
            """
        var bindings: [Binding?] = []
        for id in messageIDs { bindings.append(id) }
        var result: [Int64: Bool] = [:]
        try runQuery(sql, bindings: bindings) { row -> Void in
            let id = self.int64(row, 0) ?? 0
            let has = (self.int64(row, 1) ?? 0) != 0
            result[id] = has
        }
        return result
    }

    /// Generic query runner that hands each row to a row decoder closure.
    /// Catches SQLite errors and re-throws as `MailBladeError`.
    @discardableResult
    private func runQuery<T>(
        _ sql: String,
        bindings: [Binding?],
        decode: ([Binding?]) -> T
    ) throws -> [T] {
        do {
            let stmt = try connection.prepare(sql, bindings)
            var results: [T] = []
            for row in stmt {
                results.append(decode(row))
            }
            return results
        } catch let error as Result {
            throw Self.translate(sqliteError: error, path: config.storePath)
        } catch {
            throw MailBladeError.internalError("query: \(String(describing: error))")
        }
    }

    /// Translate a SQLite.swift `Result` into a `MailBladeError`. Maps
    /// permission-shaped failures back to `permissionDenied` so the consumer
    /// gets a clean recovery pointer.
    private static func translate(sqliteError: Result, path: String) -> MailBladeError {
        let (message, code): (String, Int32)
        switch sqliteError {
        case .error(let m, let c, _):
            (message, code) = (m, c)
        case .extendedError(let m, let extended, _):
            (message, code) = (m, extended & 0xff)
        }
        // SQLITE_AUTH = 23, SQLITE_PERM = 3, SQLITE_CANTOPEN = 14.
        if code == 23 || code == 3 {
            return .permissionDenied(path: path)
        }
        if code == 14, message.localizedCaseInsensitiveContains("unable to open") {
            return .permissionDenied(path: path)
        }
        // SQLITE_BUSY = 5, SQLITE_LOCKED = 6.
        if code == 5 || code == 6 {
            return .storeLocked
        }
        return .sqliteError(code: code, message: message)
    }

    // MARK: - Indexer hooks (DD-256 Phase A.3a)
    //
    // These two methods exist for the harness-resident
    // `AppleMailBladeIndexer` (in stallari-harness) to drive the shared
    // local-corpus FTS5 store. They're additive — no existing callers
    // touch them. Returning concrete value types (not closures or
    // protocols) keeps the SemVer surface honest: a future change here
    // must bump the blade minor version.
    //
    // Both methods read from the same connection as the rest of the
    // actor; they inherit the read-only + busy-timeout posture.

    /// One row emitted by ``messagesAfterROWID(_:limit:)`` — the precise
    /// shape the FTS5 index wants to ingest. ROWID is the upstream
    /// `messages.ROWID` so the harness query path can join back to the
    /// canonical table at search time and filter out deletions.
    public struct IndexableMessageRow: Sendable, Equatable {
        public let rowID: Int64
        public let subject: String
        public let summary: String
        public let fromAddr: String
        public let toAddrs: String

        public init(
            rowID: Int64,
            subject: String,
            summary: String,
            fromAddr: String,
            toAddrs: String
        ) {
            self.rowID = rowID
            self.subject = subject
            self.summary = summary
            self.fromAddr = fromAddr
            self.toAddrs = toAddrs
        }
    }

    /// Return up to `limit` messages whose ROWID exceeds `watermark`,
    /// ordered ascending by ROWID. Joins back to `subjects`,
    /// `summaries`, and `addresses` so the harness adapter doesn't have
    /// to re-implement the join graph.
    ///
    /// `to_addrs` is comma-joined `addresses.address` for every row in
    /// `recipients` whose `type IN (0, 1)` (`to` and `cc`). `bcc` is
    /// excluded — these rows feed an FTS5 index that surfaces in user
    /// search; bcc is an intentionally privileged channel we don't want
    /// to re-surface inadvertently.
    ///
    /// Excludes rows where `messages.deleted = 1` so the index never
    /// ingests tombstoned messages in the first place.
    public func messagesAfterROWID(_ watermark: Int64, limit: Int) throws -> [IndexableMessageRow] {
        let sql = """
            SELECT
                m.ROWID                                  AS rowid,
                COALESCE(s.subject, '')                  AS subject,
                COALESCE(sm.summary, '')                 AS summary,
                COALESCE(sender_addr.address, '')        AS from_addr,
                COALESCE((
                    SELECT GROUP_CONCAT(addr.address, ', ')
                    FROM recipients r
                    JOIN addresses addr ON addr.ROWID = r.address
                    WHERE r.message = m.ROWID AND r.type IN (0, 1)
                ), '')                                   AS to_addrs
            FROM messages m
            LEFT JOIN subjects  s           ON s.ROWID = m.subject
            LEFT JOIN summaries sm          ON sm.ROWID = m.summary
            LEFT JOIN addresses sender_addr ON sender_addr.ROWID = m.sender
            WHERE m.ROWID > ?
              AND COALESCE(m.deleted, 0) = 0
            ORDER BY m.ROWID ASC
            LIMIT ?
            """

        let stmt = try connection.prepare(sql)
        var out: [IndexableMessageRow] = []
        out.reserveCapacity(min(limit, 256))
        for row in try stmt.run(watermark, limit) {
            guard let rowID = int64(row, 0) else { continue }
            out.append(IndexableMessageRow(
                rowID: rowID,
                subject: string(row, 1) ?? "",
                summary: string(row, 2) ?? "",
                fromAddr: string(row, 3) ?? "",
                toAddrs: string(row, 4) ?? ""
            ))
        }
        return out
    }

    /// A "what version of the world is this" digest of the canonical
    /// store. Used by the indexer to decide whether an incremental tick
    /// suffices or a full reindex is required (Mail.app reorganised,
    /// account remove/re-add, mailbox URL change, …).
    ///
    /// Implementation: hash a SHA-256 of `(mailbox.url, change_identifier,
    /// total_count)` triples sorted by `mailbox.url`. Per the Schema
    /// reference (`Schema.swift`) `change_identifier` is a TEXT column on
    /// `mailboxes` that Mail.app updates when the mailbox state changes.
    /// Falling back to `total_count` covers the case where
    /// `change_identifier` is absent on a future macOS — the count alone
    /// is a coarse but safe shift signal.
    ///
    /// Returns the hex string of the SHA-256 digest. A change in any
    /// component flips the digest deterministically.
    public func currentChangeIdentifier() throws -> String {
        let stmt = try connection.prepare("""
            SELECT
                COALESCE(url, '')                AS url,
                COALESCE(change_identifier, '')  AS change_identifier,
                COALESCE(total_count, 0)         AS total_count
            FROM mailboxes
            ORDER BY url ASC
            """)

        var lines: [String] = []
        for row in try stmt.run() {
            let url = string(row, 0) ?? ""
            let changeID = string(row, 1) ?? ""
            let count = int64(row, 2) ?? 0
            lines.append("\(url)\u{1F}\(changeID)\u{1F}\(count)")
        }
        let canonical = lines.joined(separator: "\u{1E}")
        return Self.sha256Hex(canonical)
    }

    /// SHA-256(value) → lowercase hex string. CryptoKit ships with the
    /// OS so this adds no dependency.
    private static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Row helpers
    //
    // SQLite.swift yields each row as `[Binding?]`. These helpers normalise
    // the coercions we need (Int64 / Double / String) and tolerate NULL.

    private func int64(_ row: [Binding?], _ index: Int) -> Int64? {
        guard index < row.count, let value = row[index] else { return nil }
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        return nil
    }

    private func double(_ row: [Binding?], _ index: Int) -> Double? {
        guard index < row.count, let value = row[index] else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int64 { return Double(i) }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    private func string(_ row: [Binding?], _ index: Int) -> String? {
        guard index < row.count, let value = row[index] else { return nil }
        return value as? String
    }
}
