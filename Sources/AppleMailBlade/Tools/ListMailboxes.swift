import Foundation
import MCP
import MCPHelpers

/// Handler for `apple_mail_list_mailboxes`. Optional `account_id` filter.
///
/// DD-338 Phase C Wave 5: emits canonical `_meta:` envelope (B-tier promotion).
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

        let t0 = ContinuousClock.now
        do {
            let mailboxes = try await store.listMailboxes(accountID: accountID)
            let elapsed = ContinuousClock.now - t0
            var filteredBy: [String] = []
            if let accountID {
                filteredBy.append("account_id=\(accountID)")
            }
            filteredBy.sort()
            let meta = MetaEnvelope(
                matchedTotal: mailboxes.count,
                returned: mailboxes.count,
                latencyMs: elapsed.toMilliseconds(),
                filteredBy: filteredBy
            )
            return makeResultWithMeta(
                payload: ListMailboxesResponse(mailboxes: mailboxes),
                meta: meta
            )
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
