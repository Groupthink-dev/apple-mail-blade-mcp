import Foundation
import MCP

/// Handler for `apple_mail_search_messages`. v0.1.0 implementation: SQL `LIKE`
/// against `subjects.subject` + `summaries.summary` — never opens `.emlx`.
/// Real FTS attach is deferred to v0.2.0.
public struct SearchMessagesHandler: Sendable {
    public let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    public func handle(arguments: [String: Value]?) async -> CallTool.Result {
        guard case .string(let query) = arguments?["query"], !query.isEmpty else {
            return errorResult(.internalError("missing or empty query"))
        }
        let accountID: Int64? = {
            if case .int(let i) = arguments?["account_id"] { return Int64(i) }
            return nil
        }()
        let mailboxID: Int64? = {
            if case .int(let i) = arguments?["mailbox_id"] { return Int64(i) }
            return nil
        }()
        let since: Date? = {
            if case .string(let raw) = arguments?["since"] { return parseISO8601(raw) }
            return nil
        }()
        let limit: Int = {
            if case .int(let i) = arguments?["limit"] { return i }
            return 50
        }()

        do {
            let results = try await store.searchMessages(
                query: query,
                accountID: accountID,
                mailboxID: mailboxID,
                since: since,
                limit: limit
            )
            return makeResult(payload: SearchMessagesResponse(query: query, results: results))
        } catch let error as MailBladeError {
            return errorResult(error)
        } catch {
            return errorResult(.internalError(String(describing: error)))
        }
    }

    private struct SearchMessagesResponse: Codable {
        let query: String
        let results: [MessageSummary]
    }
}
