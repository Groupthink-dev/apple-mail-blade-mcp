import Foundation
import MCP

/// Handler for `apple_mail_head`. Cheap metadata lookup — never opens `.emlx`.
/// Useful for triage skills that want to decide whether a message body is
/// worth fetching.
public struct HeadHandler: Sendable {
    public let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    public func handle(arguments: [String: Value]?) async -> CallTool.Result {
        guard case .int(let idRaw) = arguments?["message_id"] else {
            return errorResult(.internalError("missing or non-integer message_id"))
        }
        let messageID = Int64(idRaw)

        do {
            let head = try await store.head(messageID: messageID)
            return makeResult(payload: head)
        } catch let error as MailBladeError {
            return errorResult(error)
        } catch {
            return errorResult(.internalError(String(describing: error)))
        }
    }
}
