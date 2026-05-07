import Foundation
import MCP

/// Handler for `apple_mail_read_message`. Opens the `.emlx` file for the
/// requested message ID, parses RFC822 headers + multipart MIME body, and
/// returns the decoded payload. HTML body is optional and returned raw —
/// not sanitised. See README §"HTML body sanitisation (privacy gotcha)".
public struct ReadMessageHandler: Sendable {
    public let store: MailStore
    public let parser: EMLXParser
    public let locator: EMLXLocator

    public init(store: MailStore, parser: EMLXParser, locator: EMLXLocator) {
        self.store = store
        self.parser = parser
        self.locator = locator
    }

    public func handle(arguments: [String: Value]?) async -> CallTool.Result {
        guard case .int(let idRaw) = arguments?["message_id"] else {
            return errorResult(.internalError("missing or non-integer message_id"))
        }
        let messageID = Int64(idRaw)
        let includeHTML: Bool = {
            if case .bool(let b) = arguments?["include_html"] { return b }
            return false
        }()

        do {
            // Index lookup first — gives a clean messageNotFound rather than
            // walking the disk for a nonexistent ID.
            let head = try await store.head(messageID: messageID)
            // Resolve the mailbox URL so the locator can scope its scan
            // to a single on-disk subtree (real V10:
            // <root>/<accountUUID>/<mailboxName>.mbox/). Falls back to a
            // pruned full-tree scan if the URL is absent or unresolvable.
            let url = (try? await store.mailboxURL(forMailboxID: head.mailboxID)) ?? nil
            let hint = url.map { MailboxHint(mailboxID: head.mailboxID, url: $0) }
            guard let path = await locator.locate(messageID: messageID, hint: hint) else {
                return errorResult(.emlxNotFound(messageID: messageID))
            }
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                return errorResult(.emlxNotFound(messageID: messageID))
            }
            let parsed = try parser.parse(
                data, messageID: messageID, includeHTML: includeHTML
            )
            let message = Message(
                id: messageID,
                mailboxID: head.mailboxID,
                messageID: head.messageID,
                conversationID: head.conversationID,
                headers: parsed.headers,
                bodyText: parsed.bodyText,
                bodyHTML: parsed.bodyHTML,
                attachmentsMeta: parsed.attachments,
                dateSent: head.dateSent,
                dateReceived: head.dateReceived
            )
            return makeResult(payload: message)
        } catch let error as MailBladeError {
            return errorResult(error)
        } catch {
            return errorResult(.internalError(String(describing: error)))
        }
    }
}
