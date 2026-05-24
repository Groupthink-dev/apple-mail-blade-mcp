import Foundation
import MCP
import MCPHelpers

/// Handler for `apple_mail_list_messages`. Index-only — never opens `.emlx`.
///
/// DD-338 Phase C Wave 5: emits canonical `_meta:` envelope (B-tier promotion).
/// `matched_total = returned` per Wave 5 OQ-4 ratification (post-LIMIT at v1;
/// avoids extra DB round-trip). `next_cursor` omitted for offset-paginated
/// tools per OQ-6 (caller reconstructs offset trivially).
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

        let sinceRaw: String? = {
            guard case .string(let raw) = arguments?["since"] else { return nil }
            return raw
        }()
        let untilRaw: String? = {
            guard case .string(let raw) = arguments?["until"] else { return nil }
            return raw
        }()
        let since: Date? = sinceRaw.flatMap { parseISO8601($0) }
        let until: Date? = untilRaw.flatMap { parseISO8601($0) }

        let limitArg: Int? = {
            if case .int(let i) = arguments?["limit"] { return i }
            return nil
        }()
        let offsetArg: Int? = {
            if case .int(let i) = arguments?["offset"] { return i }
            return nil
        }()
        let limit = limitArg ?? 100
        let offset = offsetArg ?? 0

        let t0 = ContinuousClock.now
        do {
            let messages = try await store.listMessages(
                mailboxID: mailboxID, since: since, until: until,
                limit: limit, offset: offset
            )
            let elapsed = ContinuousClock.now - t0
            var filteredBy: [String] = ["mailbox_id=\(mailboxID)"]
            if let limitArg {
                filteredBy.append("limit=\(limitArg)")
            }
            if let offsetArg {
                filteredBy.append("offset=\(offsetArg)")
            }
            if let sinceRaw {
                filteredBy.append("since=\(sinceRaw)")
            }
            if let untilRaw {
                filteredBy.append("until=\(untilRaw)")
            }
            filteredBy.sort()
            let meta = MetaEnvelope(
                matchedTotal: messages.count,
                returned: messages.count,
                latencyMs: elapsed.toMilliseconds(),
                filteredBy: filteredBy
            )
            return makeResultWithMeta(
                payload: ListMessagesResponse(messages: messages),
                meta: meta
            )
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
