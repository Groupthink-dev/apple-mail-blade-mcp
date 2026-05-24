import Foundation
import MCP
import MCPHelpers

/// Handler for `apple_mail_search_messages`. Routes between the FTS5
/// sidecar (when healthy) and the LIKE fallback inside
/// `MailStore.searchMessages`. Result shape is identical across paths.
/// FTS5 path: ~30ms p95 on a 100k-message corpus; LIKE: 600–2000ms.
/// See [[DD-256]] §A.4.
///
/// DD-338 Phase C Wave 5: emits canonical `_meta:` envelope (B-tier promotion).
/// `filtered_by` `query=` is SHA-256-12 hashed per privacy discipline (mirrors
/// W3 OQ-6 ratification for `cf_d1_query`). FTS5-fallback `redactions` deferred
/// to DEVFU `2026-05-23-apple-mail-fts5-fallback-redaction-signal`.
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
        let sinceRaw: String? = {
            if case .string(let raw) = arguments?["since"] { return raw }
            return nil
        }()
        let since: Date? = sinceRaw.flatMap { parseISO8601($0) }
        let limitArg: Int? = {
            if case .int(let i) = arguments?["limit"] { return i }
            return nil
        }()
        let limit = limitArg ?? 50

        let t0 = ContinuousClock.now
        do {
            let results = try await store.searchMessages(
                query: query,
                accountID: accountID,
                mailboxID: mailboxID,
                since: since,
                limit: limit
            )
            let elapsed = ContinuousClock.now - t0
            var filteredBy: [String] = ["query=\(metaQueryDigest(query))"]
            if let accountID {
                filteredBy.append("account_id=\(accountID)")
            }
            if let mailboxID {
                filteredBy.append("mailbox_id=\(mailboxID)")
            }
            if let sinceRaw {
                filteredBy.append("since=\(sinceRaw)")
            }
            if let limitArg {
                filteredBy.append("limit=\(limitArg)")
            }
            filteredBy.sort()
            let meta = MetaEnvelope(
                matchedTotal: results.count,
                returned: results.count,
                latencyMs: elapsed.toMilliseconds(),
                filteredBy: filteredBy
            )
            return makeResultWithMeta(
                payload: SearchMessagesResponse(query: query, results: results),
                meta: meta
            )
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
