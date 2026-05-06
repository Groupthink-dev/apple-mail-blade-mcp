import Foundation
import MCP

/// Handler for `apple_mail_read_attachment`. Reads the attachment bytes
/// from the on-disk `Attachments/` subtree, base64-encodes the payload,
/// and returns it alongside metadata. 25MB hard cap surfaces
/// `attachment_too_large` rather than partial reads.
public struct ReadAttachmentHandler: Sendable {
    public let reader: AttachmentReader

    public init(reader: AttachmentReader) {
        self.reader = reader
    }

    public func handle(arguments: [String: Value]?) async -> CallTool.Result {
        guard case .int(let midRaw) = arguments?["message_id"] else {
            return errorResult(.internalError("missing or non-integer message_id"))
        }
        guard case .int(let aidRaw) = arguments?["attachment_id"] else {
            return errorResult(.internalError("missing or non-integer attachment_id"))
        }
        let messageID = Int64(midRaw)
        let attachmentID = Int64(aidRaw)

        do {
            let bytes = try await reader.read(
                messageID: messageID, attachmentID: attachmentID
            )
            let filename = await reader.filename(
                messageID: messageID, attachmentID: attachmentID
            )
            let payload = ReadAttachmentPayload(
                messageID: messageID,
                attachmentID: attachmentID,
                filename: filename,
                byteSize: bytes.count,
                bytesBase64: bytes.base64EncodedString()
            )
            return makeResult(payload: payload)
        } catch let error as MailBladeError {
            return errorResult(error)
        } catch {
            return errorResult(.internalError(String(describing: error)))
        }
    }

    private struct ReadAttachmentPayload: Codable {
        let messageID: Int64
        let attachmentID: Int64
        let filename: String?
        let byteSize: Int
        let bytesBase64: String
    }
}
