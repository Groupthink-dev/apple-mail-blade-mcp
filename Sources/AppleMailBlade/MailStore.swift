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
                   m.message_id,
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
            LEFT JOIN addresses addr ON addr.ROWID = m.sender
            LEFT JOIN summaries summ ON summ.ROWID = m.summary
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

    /// Search messages by subject or summary substring. v0.1.0 uses `LIKE`
    /// against `subjects.subject` and `summaries.summary` — never opens
    /// `.emlx`. Real FTS attach is deferred.
    public func searchMessages(
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
                   m.message_id,
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
            LEFT JOIN addresses addr ON addr.ROWID = m.sender
            LEFT JOIN summaries summ ON summ.ROWID = m.summary
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

    /// Cheap metadata lookup. Reads only the index row — never opens `.emlx`.
    public func head(messageID: Int64) throws -> MessageHead {
        let sql = """
            SELECT m.ROWID,
                   m.mailbox,
                   m.message_id,
                   m.conversation_id,
                   s.subject,
                   addr.address,
                   m.date_sent,
                   m.date_received,
                   m.read,
                   m.flagged,
                   m.size,
                   m.in_reply_to
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses addr ON addr.ROWID = m.sender
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
                inReplyTo: string(row, 11)
            )
        }
        guard let head = rows.first else {
            throw MailBladeError.messageNotFound(id: messageID)
        }
        // Single-row attachment-presence lookup.
        let attachMap = try fetchAttachmentPresence(messageIDs: [messageID])
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
            inReplyTo: head.inReplyTo
        )
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
