import Foundation
import MCP

/// JSON encoder used by all tool handlers. ISO-8601 dates with fractional
/// seconds; pretty-print disabled (consumer-facing JSON, not human-edit).
/// Constructed per-call to avoid Swift 6 strict-concurrency complaints about
/// `JSONEncoder` instances at module scope.
private func makeToolEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.keyEncodingStrategy = .useDefaultKeys
    return e
}

/// Wrap any `Codable` payload as a `CallTool.Result` with a single `.text`
/// content item containing the JSON-encoded payload. On encoding failure
/// returns an internal-error result.
func makeResult<T: Codable>(payload: T) -> CallTool.Result {
    do {
        let data = try makeToolEncoder().encode(payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)])
    } catch {
        return CallTool.Result(
            content: [.text(text: #"{"error":"encode_failure"}"#, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

/// Wrap a `MailBladeError` as an error result. The `error` shape is stable;
/// consumer-side skills can switch on `error.code`.
func errorResult(_ error: MailBladeError) -> CallTool.Result {
    let payload = ErrorPayload(error: ErrorBody(from: error))
    do {
        let data = try makeToolEncoder().encode(payload)
        let json = String(data: data, encoding: .utf8) ?? #"{"error":{"code":"unknown"}}"#
        return CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)], isError: true)
    } catch {
        return CallTool.Result(
            content: [.text(text: #"{"error":{"code":"encode_failure"}}"#, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}

private struct ErrorPayload: Codable {
    let error: ErrorBody
}

private struct ErrorBody: Codable {
    let code: String
    let message: String
    let path: String?
    let recovery: String?
    let messageID: Int64?
    let attachmentID: Int64?
    let toolName: String?

    init(from error: MailBladeError) {
        switch error {
        case .permissionDenied(let path):
            self.code = "permission_denied"
            self.message = "Full Disk Access required to read \(path)."
            self.path = path
            self.recovery = MailBladeError.pointerToFullDiskAccess
            self.messageID = nil
            self.attachmentID = nil
            self.toolName = nil
        case .storeMissing(let path):
            self.code = "store_missing"
            self.message = "Envelope Index not found at \(path)."
            self.path = path
            self.recovery = nil
            self.messageID = nil
            self.attachmentID = nil
            self.toolName = nil
        case .storeLocked:
            self.code = "store_locked"
            self.message = "Envelope Index is busy; retry later."
            self.path = nil
            self.recovery = nil
            self.messageID = nil
            self.attachmentID = nil
            self.toolName = nil
        case .invalidStorePath(let path):
            self.code = "invalid_store_path"
            self.message = "Store path \(path) is outside the allowed prefixes."
            self.path = path
            self.recovery = nil
            self.messageID = nil
            self.attachmentID = nil
            self.toolName = nil
        case .messageNotFound(let id):
            self.code = "message_not_found"
            self.message = "Message id=\(id) not found in the index."
            self.path = nil
            self.recovery = nil
            self.messageID = id
            self.attachmentID = nil
            self.toolName = nil
        case .emlxNotFound(let id):
            self.code = "emlx_not_found"
            self.message = ".emlx file missing for message id=\(id)."
            self.path = nil
            self.recovery = nil
            self.messageID = id
            self.attachmentID = nil
            self.toolName = nil
        case .decodeFailure(let id, let reason):
            self.code = "decode_failure"
            self.message = "Failed to decode message: \(reason)"
            self.path = nil
            self.recovery = nil
            self.messageID = id
            self.attachmentID = nil
            self.toolName = nil
        case .attachmentTooLarge(let mid, let aid, let bytes):
            self.code = "attachment_too_large"
            self.message =
                "Attachment exceeds 25MB cap. Size: \(bytes) bytes."
            self.path = nil
            self.recovery = nil
            self.messageID = mid
            self.attachmentID = aid
            self.toolName = nil
        case .notImplemented(let tool):
            self.code = "not_implemented"
            self.message = "Tool \(tool) is not yet implemented in this release."
            self.path = nil
            self.recovery = nil
            self.messageID = nil
            self.attachmentID = nil
            self.toolName = tool
        case .sqliteError(let code, let msg):
            self.code = "sqlite_error"
            self.message = "SQLite error code=\(code): \(msg)"
            self.path = nil
            self.recovery = nil
            self.messageID = nil
            self.attachmentID = nil
            self.toolName = nil
        case .internalError(let label):
            self.code = "internal_error"
            self.message = label
            self.path = nil
            self.recovery = nil
            self.messageID = nil
            self.attachmentID = nil
            self.toolName = nil
        }
    }
}

/// ISO-8601 parser shared across tool handlers. Accepts both
/// with-fractional-seconds and bare forms.
func parseISO8601(_ raw: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: raw) { return d }
    let bare = ISO8601DateFormatter()
    bare.formatOptions = [.withInternetDateTime]
    return bare.date(from: raw)
}
