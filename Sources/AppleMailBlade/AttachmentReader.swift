import Foundation

/// Reads attachment bytes from the on-disk `Attachments/` subtree.
///
/// Apple stores attachments separately from `.emlx` bodies under
/// `<mboxUUID>/Attachments/<messageID>/<part-index>/<filename>`. Walking the
/// subtree gives us enumerable attachment files; the part index matches the
/// MIME walker's enumeration order in `EMLXParser`.
///
/// Hard cap: `MailBladeConfig.maxAttachmentBytes` (default 25MB). Attachments
/// exceeding the cap surface `attachmentTooLarge` rather than partial reads.
public struct AttachmentReader: Sendable {

    public let config: MailBladeConfig
    public let locator: EMLXLocator

    public init(config: MailBladeConfig, locator: EMLXLocator) {
        self.config = config
        self.locator = locator
    }

    /// Read attachment `attachmentID` (zero-based) from message `messageID`.
    /// Returns the attachment bytes plus the MIME type inferred from the
    /// filename extension, or throws on failure.
    /// Pass a `MailboxHint` when known — bounds the on-disk scan to one
    /// mailbox subtree; without it, the locator falls back to a pruned
    /// full-tree scan.
    public func read(
        messageID: Int64, attachmentID: Int64, hint: MailboxHint? = nil
    ) async throws -> Data {
        guard
            let attachmentsDir = await locator.attachmentsRoot(
                messageID: messageID, hint: hint
            )
        else {
            throw MailBladeError.emlxNotFound(messageID: messageID)
        }
        let partDir = "\(attachmentsDir)/\(attachmentID)"
        guard FileManager.default.fileExists(atPath: partDir) else {
            throw MailBladeError.internalError(
                "attachment id \(attachmentID) not found for message \(messageID)"
            )
        }
        // Walk the part directory for the first regular file.
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: partDir) else {
            throw MailBladeError.internalError("could not list attachment directory")
        }
        for entry in entries {
            let filePath = "\(partDir)/\(entry)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: filePath, isDirectory: &isDir), !isDir.boolValue
            else { continue }
            let attrs = try fm.attributesOfItem(atPath: filePath)
            let size = (attrs[.size] as? Int) ?? 0
            if size > config.maxAttachmentBytes {
                throw MailBladeError.attachmentTooLarge(
                    messageID: messageID,
                    attachmentID: attachmentID,
                    byteSize: size
                )
            }
            return try Data(contentsOf: URL(fileURLWithPath: filePath))
        }
        throw MailBladeError.internalError(
            "no regular file in attachment directory \(partDir)"
        )
    }

    /// Filename of the on-disk attachment file (last component). Returns
    /// `nil` if the message or attachment can't be located.
    public func filename(
        messageID: Int64, attachmentID: Int64, hint: MailboxHint? = nil
    ) async -> String? {
        guard
            let attachmentsDir = await locator.attachmentsRoot(
                messageID: messageID, hint: hint
            )
        else {
            return nil
        }
        let partDir = "\(attachmentsDir)/\(attachmentID)"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: partDir) else { return nil }
        for entry in entries {
            let filePath = "\(partDir)/\(entry)"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: filePath, isDirectory: &isDir), !isDir.boolValue {
                return entry
            }
        }
        return nil
    }
}
