import Foundation

/// Documented field reference for the Apple Mail Envelope Index V10 schema
/// (macOS 14+).
///
/// Mail.app stores message metadata in a SQLite database at
/// `~/Library/Mail/V10/MailData/Envelope Index`. Message bodies live in
/// per-message `.emlx` files under the per-account mailbox directory tree,
/// not in this database — `.emlx` parsing lands in Phase A.2.
///
/// **Schema is best-effort published documentation.** Apple does not publish
/// this schema; column names and types are reverse-engineered from the
/// running database in macOS 14/15. The Phase A.1 gate is a manual real-DB
/// smoke test on `~/Library/Mail/V10/MailData/Envelope Index` — divergence
/// from this reference becomes a Phase A.1.1 schema-correction follow-up.
///
/// Tables we reference in v0.1.0:
///
/// - `messages` — primary message records.
///   ROWID (PK), message_id (TEXT), document_id (TEXT, UUID), in_reply_to (TEXT),
///   remote_id (TEXT), sender (INTEGER FK → addresses), subject_prefix (TEXT),
///   subject (INTEGER FK → subjects), date_sent (REAL, unix epoch),
///   date_received (REAL, unix epoch), date_last_viewed (REAL),
///   mailbox (INTEGER FK → mailboxes), original_mailbox (INTEGER FK → mailboxes),
///   flags (INTEGER bitfield), read (INTEGER 0/1), flagged (INTEGER 0/1),
///   deleted (INTEGER 0/1), size (INTEGER bytes), conversation_id (INTEGER),
///   summary (INTEGER FK → summaries), color (INTEGER), encoding (INTEGER).
///
/// - `mailboxes` — mailbox enumeration.
///   ROWID (PK), url (TEXT — e.g. `imap://user@host/INBOX` or
///   `local://localmac/On%20My%20Mac/Archive`), total_count (INTEGER),
///   unread_count (INTEGER), unseen_count (INTEGER),
///   change_identifier (TEXT).
///
/// - `addresses` — sender/recipient address strings.
///   ROWID (PK), address (TEXT — e.g. `piers@mm.st`),
///   comment (TEXT — display name).
///
/// - `subjects` — deduplicated subject strings.
///   ROWID (PK), subject (TEXT), normalized_subject (TEXT — `Re:`/`Fwd:` stripped).
///
/// - `recipients` — message-to-address join with type (to/cc/bcc).
///   ROWID (PK), message (INTEGER FK → messages), address (INTEGER FK → addresses),
///   type (INTEGER 0=to, 1=cc, 2=bcc), position (INTEGER).
///
/// - `summaries` — body summary/snippet text (when Mail.app has summarised).
///   ROWID (PK), summary (TEXT).
///
/// **Accounts model.** v0.1.0 derives accounts from `mailboxes.url` rather
/// than depending on a separate `accounts` table. The URL prefix
/// `<scheme>://<user>@<host>` is the account-key; mailboxes sharing the same
/// prefix belong to the same account. Synthetic Int64 IDs are assigned
/// deterministically (sorted account-key → 1-based ROW_NUMBER). This keeps
/// the API stable even on machines where the `accounts` table is absent or
/// schemas vary across macOS versions.
public enum MailSchema {

    /// Recipient type constants stored in `recipients.type`.
    public enum RecipientType {
        public static let to: Int64 = 0
        public static let cc: Int64 = 1
        public static let bcc: Int64 = 2
    }

    /// `messages.flags` bits we care about. Bitfield is per-Apple, so
    /// dedicated read/flagged/deleted columns are preferred where present.
    public enum MessageFlag {
        public static let read: Int64 = 1 << 0
        public static let deleted: Int64 = 1 << 1
        public static let answered: Int64 = 1 << 2
        public static let flagged: Int64 = 1 << 4
    }

    /// `messages.date_sent` and `date_received` are Unix epoch seconds (REAL),
    /// **not** Apple Core Data 2001-epoch timestamps. Convert via
    /// `Date(timeIntervalSince1970:)`.
    public static func date(fromUnixEpoch seconds: Double?) -> Date? {
        guard let s = seconds, s != 0 else { return nil }
        return Date(timeIntervalSince1970: s)
    }

    /// Parse `mailboxes.url` to an account-key — the canonical grouping
    /// identifier for accounts. Returns the URL itself if it can't be parsed
    /// to a `scheme://user@host` shape; never returns nil for a non-empty URL.
    ///
    /// Examples:
    /// - `imap://piers%40mm.st@imap.fastmail.com/INBOX` → `imap://piers%40mm.st@imap.fastmail.com`
    /// - `local://localmac/On%20My%20Mac/Archive` → `local://localmac`
    /// - `ews://piers@outlook.office365.com/Inbox` → `ews://piers@outlook.office365.com`
    public static func accountKey(fromMailboxURL url: String) -> String {
        guard !url.isEmpty else { return "unknown://" }
        // Find first `/` after `scheme://`. Everything before that is the prefix.
        if let schemeRange = url.range(of: "://") {
            let afterScheme = url.index(schemeRange.upperBound, offsetBy: 0)
            if let nextSlash = url[afterScheme...].firstIndex(of: "/") {
                return String(url[..<nextSlash])
            }
            return url
        }
        return url
    }

    /// Best-effort human label for an account derived from a mailbox URL.
    /// Falls back to the account-key when parsing fails. Never returns empty.
    public static func accountDisplayName(fromMailboxURL url: String) -> String {
        let key = accountKey(fromMailboxURL: url)
        // Strip scheme://
        guard let schemeRange = key.range(of: "://") else { return key }
        let body = String(key[schemeRange.upperBound...])
        // Percent-decode user portion if present.
        let decoded = body.removingPercentEncoding ?? body
        return decoded.isEmpty ? key : decoded
    }
}
