import Foundation

/// Error vocabulary for the Mail blade. Errors **carry IDs and paths only** —
/// never message bodies, subjects, or sender addresses — to keep error
/// surfaces non-leaking when they bubble up through traces / logs.
public enum MailBladeError: Error, Sendable, Equatable {
    /// Full Disk Access not granted on the consuming binary. The associated
    /// path is the absolute store path that we attempted to open. Recovery
    /// pointer is `pointerToFullDiskAccess` below.
    case permissionDenied(path: String)

    /// `Envelope Index` does not exist at the configured path. Likely cause:
    /// macOS path schema change, or the user has never opened Mail.app on
    /// this Mac.
    case storeMissing(path: String)

    /// SQLite returned `SQLITE_BUSY` past the busy-timeout window. The store
    /// is being held exclusively by another writer (Mail.app sync, Spotlight
    /// indexing). Caller should retry with a small backoff or give up.
    case storeLocked

    /// `Config.storePath` was set to a value outside the allowed prefixes
    /// (`/private/tmp/*` and the canonical `~/Library/Mail/V10/` path).
    /// Carries the rejected path.
    case invalidStorePath(path: String)

    /// Requested message ID does not exist in the index.
    case messageNotFound(id: Int64)

    /// `.emlx` file expected at the resolved on-disk path is missing.
    /// Lands at Phase A.2; reserved here so the error vocabulary is stable.
    case emlxNotFound(messageID: Int64)

    /// `.emlx` parser hit one of its bounded-recursion / max-size guards or
    /// the byte stream is malformed. Reserved for Phase A.2; carries the
    /// message ID for correlation but never the body.
    case decodeFailure(messageID: Int64, reason: String)

    /// Attachment exceeded the 25MB hard cap. Reserved for Phase A.2.
    case attachmentTooLarge(messageID: Int64, attachmentID: Int64, byteSize: Int)

    /// Caller invoked a tool that has not yet been implemented in this
    /// release. Surface during phased rollout (e.g. `read_message` before
    /// Phase A.2 lands). Carries the tool name.
    case notImplemented(toolName: String)

    /// SQLite layer reported an unexpected condition. Phrased generically to
    /// avoid leaking schema details into traces.
    case sqliteError(code: Int32, message: String)

    /// Catchall for assertion-shaped surprises. Always carries a short label.
    case internalError(String)
}

extension MailBladeError {
    /// Stable pointer string included in `permissionDenied` errors so the
    /// consuming skill / UI can surface the exact System Settings pane.
    public static let pointerToFullDiskAccess =
        "Open System Settings → Privacy & Security → Full Disk Access and enable Stallari."

    /// Human-readable summary suitable for logging. **Never** includes message
    /// bodies, subjects, or addresses; message/attachment IDs are surfaced
    /// for debug correlation only.
    public var loggableDescription: String {
        switch self {
        case .permissionDenied(let path):
            return "permissionDenied: cannot read \(path) — \(Self.pointerToFullDiskAccess)"
        case .storeMissing(let path):
            return "storeMissing: \(path) does not exist"
        case .storeLocked:
            return "storeLocked: Envelope Index is busy; retry later"
        case .invalidStorePath(let path):
            return "invalidStorePath: \(path) is outside the allowed prefixes"
        case .messageNotFound(let id):
            return "messageNotFound: message id=\(id)"
        case .emlxNotFound(let id):
            return "emlxNotFound: .emlx file missing for message id=\(id)"
        case .decodeFailure(let id, let reason):
            return "decodeFailure: message id=\(id) reason=\(reason)"
        case .attachmentTooLarge(let mid, let aid, let bytes):
            return
                "attachmentTooLarge: message id=\(mid) attachment id=\(aid) bytes=\(bytes) (cap=25MB)"
        case .notImplemented(let tool):
            return "notImplemented: tool \(tool) lands in a later phase"
        case .sqliteError(let code, let message):
            return "sqliteError: code=\(code) message=\(message)"
        case .internalError(let label):
            return "internalError: \(label)"
        }
    }
}
