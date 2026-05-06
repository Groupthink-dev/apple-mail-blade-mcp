import Foundation
import MCP

/// Handler for `apple_mail_extract_entities`. Loads the message body via the
/// same `.emlx` path used by `read_message`, then runs deterministic
/// `NaturalLanguage` extraction (NLTagger + NLLanguageRecognizer) plus
/// `NSDataDetector` date extraction. No persistence, no caching — every
/// call recomputes.
public struct ExtractEntitiesHandler: Sendable {
    public let store: MailStore
    public let parser: EMLXParser
    public let locator: EMLXLocator
    public let extractor: EntityExtractor

    public init(
        store: MailStore,
        parser: EMLXParser,
        locator: EMLXLocator,
        extractor: EntityExtractor
    ) {
        self.store = store
        self.parser = parser
        self.locator = locator
        self.extractor = extractor
    }

    public func handle(arguments: [String: Value]?) async -> CallTool.Result {
        guard case .int(let idRaw) = arguments?["message_id"] else {
            return errorResult(.internalError("missing or non-integer message_id"))
        }
        let messageID = Int64(idRaw)

        do {
            // Index lookup first — clean message_not_found if the ID isn't real.
            _ = try await store.head(messageID: messageID)
            guard let path = await locator.locate(messageID: messageID) else {
                return errorResult(.emlxNotFound(messageID: messageID))
            }
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                return errorResult(.emlxNotFound(messageID: messageID))
            }
            let parsed = try parser.parse(
                data, messageID: messageID, includeHTML: false
            )
            let bodyText = parsed.bodyText ?? ""
            let entities = extractor.extract(messageID: messageID, bodyText: bodyText)
            return makeResult(payload: entities)
        } catch let error as MailBladeError {
            return errorResult(error)
        } catch {
            return errorResult(.internalError(String(describing: error)))
        }
    }
}
