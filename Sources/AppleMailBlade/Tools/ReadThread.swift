import Foundation
import MCP
import MCPHelpers

/// Handler for `apple_mail_read_thread`. Reconstructs a thread starting
/// from the requested message ID. Walks `messages.conversation_id` first,
/// falls back to `In-Reply-To` / `References` headers. Cross-account hops
/// are flagged on each `ThreadMessage`.
///
/// DD-338 Phase C Wave 5: emits canonical `_meta:` envelope (B-tier promotion).
/// `redactions: ["cross_account_hops=N"]` REQUIRED when N > 0 per OQ-3 (b)
/// ratification — load-bearing for DD-278 scope-violation audit on
/// cross-account thread reconstruction. Coupled with `apple_mail_list_accounts`
/// staying C (audit baseline for these hops).
public struct ReadThreadHandler: Sendable {
    public let resolver: ThreadResolver

    public init(resolver: ThreadResolver) {
        self.resolver = resolver
    }

    public func handle(arguments: [String: Value]?) async -> CallTool.Result {
        guard case .int(let idRaw) = arguments?["message_id"] else {
            return errorResult(.internalError("missing or non-integer message_id"))
        }
        let messageID = Int64(idRaw)

        let t0 = ContinuousClock.now
        do {
            let thread = try await resolver.resolve(messageID: messageID)
            let elapsed = ContinuousClock.now - t0
            let crossAccountCount = thread.filter { $0.crossAccount }.count
            let redactions: [String] = crossAccountCount > 0
                ? ["cross_account_hops=\(crossAccountCount)"]
                : []
            let meta = MetaEnvelope(
                matchedTotal: thread.count,
                returned: thread.count,
                latencyMs: elapsed.toMilliseconds(),
                filteredBy: ["message_id=\(messageID)"],
                redactions: redactions
            )
            return makeResultWithMeta(
                payload: ReadThreadResponse(thread: thread),
                meta: meta
            )
        } catch let error as MailBladeError {
            return errorResult(error)
        } catch {
            return errorResult(.internalError(String(describing: error)))
        }
    }

    private struct ReadThreadResponse: Codable {
        let thread: [ThreadMessage]
    }
}
