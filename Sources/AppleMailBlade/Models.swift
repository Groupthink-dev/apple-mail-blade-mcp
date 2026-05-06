import Foundation

// MARK: - Public model types
//
// These shapes are what the tool handlers return. They serialise to JSON via
// Codable; field naming uses camelCase on the wire because consumers are
// internal Stallari skills which already speak camelCase.

/// An account derived from `mailboxes.url` prefixes (see
/// `MailSchema.accountKey(fromMailboxURL:)`). `id` is a synthetic Int64
/// assigned deterministically by sorted account-key order; it is stable as
/// long as the set of accounts on the machine is stable.
public struct Account: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let accountKey: String  // Canonical "scheme://user@host" prefix
    public let mailboxCount: Int
}

public struct Mailbox: Codable, Sendable, Equatable {
    public let id: Int64
    public let accountID: Int64
    public let url: String
    public let name: String
    public let totalCount: Int
    public let unreadCount: Int
    public let unseenCount: Int
}

/// Per-message envelope summary. Index-only — never sourced from `.emlx`.
public struct MessageSummary: Codable, Sendable, Equatable {
    public let id: Int64
    public let mailboxID: Int64
    public let messageID: String?  // RFC822 Message-ID header value
    public let conversationID: Int64?
    public let subject: String?
    public let from: String?  // Sender address (single value from `messages.sender`)
    public let to: [String]  // To-recipients enumerated from `recipients`
    public let dateSent: Date?
    public let dateReceived: Date?
    public let isRead: Bool
    public let isFlagged: Bool
    public let hasAttachments: Bool
    public let snippet: String?  // From `summaries.summary` if present
    public let sizeBytes: Int?
}

/// Cheap metadata lookup payload. Reads only the index — never opens `.emlx`.
public struct MessageHead: Codable, Sendable, Equatable {
    public let id: Int64
    public let mailboxID: Int64
    public let messageID: String?
    public let conversationID: Int64?
    public let subject: String?
    public let from: String?
    public let dateSent: Date?
    public let dateReceived: Date?
    public let isRead: Bool
    public let isFlagged: Bool
    public let hasAttachments: Bool
    public let sizeBytes: Int?
    public let inReplyTo: String?  // Parent message-id from `messages.in_reply_to`
}

/// Attachment metadata enumerated from MIME parts. Lands in Phase A.2; defined
/// here so the type vocabulary is stable across phases.
public struct AttachmentMeta: Codable, Sendable, Equatable {
    public let id: Int64
    public let messageID: Int64
    public let filename: String?
    public let mimeType: String?
    public let contentID: String?  // For inline images referenced via cid:
    public let byteSize: Int?
}

/// Full message payload — headers + body + attachment metadata. Lands in
/// Phase A.2 when the `.emlx` parser ships; defined here so v0.1.0's
/// `apple_mail_read_message` schema can reference it.
public struct Message: Codable, Sendable, Equatable {
    public let id: Int64
    public let mailboxID: Int64
    public let messageID: String?
    public let conversationID: Int64?
    public let headers: [String: [String]]
    public let bodyText: String?
    public let bodyHTML: String?
    public let attachmentsMeta: [AttachmentMeta]
    public let dateSent: Date?
    public let dateReceived: Date?
}

/// Single message inside a thread. Lands in Phase A.2.
public struct ThreadMessage: Codable, Sendable, Equatable {
    public let id: Int64
    public let mailboxID: Int64
    public let messageID: String?
    public let inReplyTo: String?
    public let subject: String?
    public let from: String?
    public let dateSent: Date?
    public let bodyText: String?
    public let crossAccount: Bool  // True if this message lives in a different account from the thread root
}

/// NLTagger entity extraction payload. Lands in Phase A.3.
public struct Entities: Codable, Sendable, Equatable {
    public let messageID: Int64
    public let language: String  // ISO 639-1, or "und" for undetermined
    public let people: [String]
    public let orgs: [String]
    public let places: [String]
    public let dates: [String]
}
