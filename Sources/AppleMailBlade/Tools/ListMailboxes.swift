import Foundation
import MCP

/// Handler for `apple_mail_list_mailboxes`. Optional `account_id` filter.
public struct ListMailboxesHandler: Sendable {
    public let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    public func handle(arguments: [String: Value]?) async -> CallTool.Result {
        let accountID: Int64? = {
            guard case .int(let i) = arguments?["account_id"] else { return nil }
            return Int64(i)
        }()

        do {
            let mailboxes = try await store.listMailboxes(accountID: accountID)
            return makeResult(payload: ListMailboxesResponse(mailboxes: mailboxes))
        } catch let error as MailBladeError {
            return errorResult(error)
        } catch {
            return errorResult(.internalError(String(describing: error)))
        }
    }

    private struct ListMailboxesResponse: Codable {
        let mailboxes: [Mailbox]
    }
}
