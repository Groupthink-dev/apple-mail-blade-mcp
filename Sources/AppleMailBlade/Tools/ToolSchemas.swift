import Foundation
import MCP

/// MCP tool schema definitions for the Mail blade.
///
/// Tool naming uses the `apple_mail_*` prefix so the broader internal tool
/// catalog stays unambiguous when sibling blades (notes, reminders, etc.)
/// register alongside.
///
/// **Phasing.** v0.1.0 Phase A.1 ships 5 tools as fully-functional handlers:
/// `list_accounts`, `list_mailboxes`, `list_messages`, `search_messages`,
/// `head`. Three more — `read_message`, `read_attachment`, `read_thread` —
/// have schemas defined here but their handlers return `not_implemented`
/// until Phase A.2 wires the `.emlx` parser. `extract_entities` lands at
/// Phase A.3 (NLTagger). Schemas are defined now so the surface stays
/// stable for tooling consumers.
public enum MailToolSchemas {

    // MARK: - Phase A.1 (active)

    public static let listAccounts = Tool(
        name: "apple_mail_list_accounts",
        description:
            "List Apple Mail accounts derived from mailbox URL prefixes. "
            + "Returns synthetic account IDs that are stable across calls "
            + "for a given machine.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )

    public static let listMailboxes = Tool(
        name: "apple_mail_list_mailboxes",
        description: "List Apple Mail mailboxes. Optional account_id filter.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "account_id": .object([
                    "type": .string("integer"),
                    "description": .string("Optional. Limit mailboxes to this synthetic account ID."),
                ])
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    public static let listMessages = Tool(
        name: "apple_mail_list_messages",
        description:
            "List messages within a mailbox. Index-only — does NOT open .emlx files. "
            + "Returns subject, from, to, dates, read/flagged state, snippet, attachment-presence flag.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("mailbox_id")]),
            "properties": .object([
                "mailbox_id": .object([
                    "type": .string("integer"),
                    "description": .string("Mailbox ROWID (from list_mailboxes)."),
                ]),
                "since": .object([
                    "type": .string("string"),
                    "format": .string("date-time"),
                    "description": .string("Optional. ISO-8601 lower bound on date_received."),
                ]),
                "until": .object([
                    "type": .string("string"),
                    "format": .string("date-time"),
                    "description": .string("Optional. ISO-8601 upper bound on date_received."),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(1000),
                    "default": .int(100),
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "minimum": .int(0),
                    "default": .int(0),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    public static let searchMessages = Tool(
        name: "apple_mail_search_messages",
        description:
            "Search messages by subject or summary substring (LIKE-based, fast). "
            + "Never opens .emlx. Optional account_id / mailbox_id / since filters.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("query")]),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "minLength": .int(1),
                    "description": .string("Substring to match in message subject or summary."),
                ]),
                "account_id": .object([
                    "type": .string("integer"),
                    "description": .string("Optional. Limit search to this synthetic account ID."),
                ]),
                "mailbox_id": .object([
                    "type": .string("integer"),
                    "description": .string("Optional. Limit search to this mailbox ROWID."),
                ]),
                "since": .object([
                    "type": .string("string"),
                    "format": .string("date-time"),
                    "description": .string("Optional. ISO-8601 lower bound on date_received."),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(1000),
                    "default": .int(50),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    public static let head = Tool(
        name: "apple_mail_head",
        description:
            "Cheap metadata lookup for a single message. Returns subject, from, "
            + "dates, read/flagged state, attachment-presence flag, in_reply_to. "
            + "Never opens .emlx. Use to decide whether to call read_message.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("message_id")]),
            "properties": .object([
                "message_id": .object([
                    "type": .string("integer"),
                    "description": .string("Message ROWID (from list_messages)."),
                ])
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    // MARK: - Phase A.2 (schemas defined; handlers return not_implemented)

    public static let readMessage = Tool(
        name: "apple_mail_read_message",
        description:
            "Read a single message body. Opens the .emlx file, parses RFC822 headers + "
            + "multipart MIME body, returns plain text + (optionally) HTML + attachments metadata. "
            + "Phase A.2 — currently returns not_implemented.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("message_id")]),
            "properties": .object([
                "message_id": .object([
                    "type": .string("integer"),
                    "description": .string("Message ROWID."),
                ]),
                "include_html": .object([
                    "type": .string("boolean"),
                    "default": .bool(false),
                    "description": .string("If true, include HTML body when present. Raw — not sanitised."),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    public static let readAttachment = Tool(
        name: "apple_mail_read_attachment",
        description:
            "Read a single attachment from the Attachments/ subtree. Returns base64-encoded bytes. "
            + "25MB hard cap — larger attachments surface attachment_too_large. Phase A.2 — currently "
            + "returns not_implemented.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("message_id"), .string("attachment_id")]),
            "properties": .object([
                "message_id": .object([
                    "type": .string("integer"),
                    "description": .string("Message ROWID."),
                ]),
                "attachment_id": .object([
                    "type": .string("integer"),
                    "description": .string("Attachment index from read_message attachmentsMeta."),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    public static let readThread = Tool(
        name: "apple_mail_read_thread",
        description:
            "Reconstruct a thread starting from a message. Walks conversation_id first, "
            + "falls back to In-Reply-To / References headers. Cross-account hops flagged. "
            + "Phase A.2 — currently returns not_implemented.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("message_id")]),
            "properties": .object([
                "message_id": .object([
                    "type": .string("integer"),
                    "description": .string("Message ROWID — the thread is rooted at this message's conversation."),
                ])
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    // MARK: - Phase A.3 (schema defined; handler returns not_implemented)

    public static let extractEntities = Tool(
        name: "apple_mail_extract_entities",
        description:
            "Run NLTagger over a message body to extract people, organisations, places, dates, and "
            + "the detected language. Deterministic — uses Apple's NaturalLanguage framework, no LLM. "
            + "Phase A.3 — currently returns not_implemented.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("message_id")]),
            "properties": .object([
                "message_id": .object([
                    "type": .string("integer"),
                    "description": .string("Message ROWID."),
                ])
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    /// All tool schemas in registration order — 9 tools total.
    public static func all() -> [Tool] {
        [
            listAccounts, listMailboxes, listMessages, searchMessages, head,
            readMessage, readAttachment, readThread,
            extractEntities,
        ]
    }
}
