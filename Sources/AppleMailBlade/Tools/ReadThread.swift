import Foundation
import MCP

/// Handler for `apple_mail_read_thread`. Reconstructs a thread starting
/// from the requested message ID. Walks `messages.conversation_id` first,
/// falls back to `In-Reply-To` / `References` headers. Cross-account hops
/// are flagged on each `ThreadMessage`.
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

        do {
            let thread = try await resolver.resolve(messageID: messageID)
            return makeResult(payload: ReadThreadResponse(thread: thread))
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
