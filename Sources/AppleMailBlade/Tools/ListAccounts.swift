import Foundation
import MCP
import MCPHelpers

/// Handler for `apple_mail_list_accounts`. Derives accounts from `mailboxes.url`
/// prefixes — see `MailSchema.accountKey(fromMailboxURL:)`. No arguments.
///
/// DD-338 Phase C Wave 5: emits canonical `_meta:` envelope (C-tier promotion
/// per OQ-3 ratification — envelope discloses account-cardinality baseline
/// that `apple_mail_read_thread` cross-account-hops are measured against).
public struct ListAccountsHandler: Sendable {
    public let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    public func handle(arguments _: [String: Value]?) async -> CallTool.Result {
        let t0 = ContinuousClock.now
        do {
            let accounts = try await store.listAccounts()
            let elapsed = ContinuousClock.now - t0
            let meta = MetaEnvelope(
                matchedTotal: accounts.count,
                returned: accounts.count,
                latencyMs: elapsed.toMilliseconds(),
                filteredBy: []
            )
            return makeResultWithMeta(
                payload: ListAccountsResponse(accounts: accounts),
                meta: meta
            )
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
