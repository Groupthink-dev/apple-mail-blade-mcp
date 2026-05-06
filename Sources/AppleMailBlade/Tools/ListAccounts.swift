import Foundation
import MCP

/// Handler for `apple_mail_list_accounts`. Derives accounts from `mailboxes.url`
/// prefixes — see `MailSchema.accountKey(fromMailboxURL:)`. No arguments.
public struct ListAccountsHandler: Sendable {
    public let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    public func handle(arguments _: [String: Value]?) async -> CallTool.Result {
        do {
            let accounts = try await store.listAccounts()
            return makeResult(payload: ListAccountsResponse(accounts: accounts))
        } catch let error as MailBladeError {
            return errorResult(error)
        } catch {
            return errorResult(.internalError(String(describing: error)))
        }
    }

    private struct ListAccountsResponse: Codable {
        let accounts: [Account]
    }
}
