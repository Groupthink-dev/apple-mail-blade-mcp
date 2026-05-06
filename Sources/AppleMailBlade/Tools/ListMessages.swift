import Foundation
import MCP

/// Handler for `apple_mail_list_messages`. Index-only — never opens `.emlx`.
public struct ListMessagesHandler: Sendable {
    public let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    public func handle(arguments: [String: Value]?) async -> CallTool.Result {
        guard case .int(let mailboxRaw) = arguments?["mailbox_id"] else {
            return errorResult(.internalError("missing or non-integer mailbox_id"))
        }
        let mailboxID = Int64(mailboxRaw)

        let since: Date? = {
            guard case .string(let raw) = arguments?["since"] else { return nil }
            return parseISO8601(raw)
        }()
        let until: Date? = {
            guard case .string(let raw) = arguments?["until"] else { return nil }
            return parseISO8601(raw)
        }()
        let limit: Int = {
            if case .int(let i) = arguments?["limit"] { return i }
            return 100
        }()
        let offset: Int = {
            if case .int(let i) = arguments?["offset"] { return i }
            return 0
        }()

        do {
            let messages = try await store.listMessages(
                mailboxID: mailboxID, since: since, until: until,
                limit: limit, offset: offset
            )
            return makeResult(payload: ListMessagesResponse(messages: messages))
        } catch let error as MailBladeError {
            return errorResult(error)
        } catch {
            return errorResult(.internalError(String(describing: error)))
        }
    }

    private struct ListMessagesResponse: Codable {
        let messages: [MessageSummary]
    }
}
