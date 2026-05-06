import Foundation

/// Runtime configuration for the Mail blade.
///
/// Path validation is **strict**: `storePath` must point at the canonical
/// `~/Library/Mail/V10/MailData/Envelope Index` or under `/private/tmp/`
/// (for fixture tests). Any other prefix is rejected at construction time
/// with `MailBladeError.invalidStorePath` — this is one of the secops
/// invariants (DD-240 #4 + access-policy section "Local-corpus blade access").
public struct MailBladeConfig: Sendable {

    /// Absolute path to `Envelope Index` SQLite. Defaults to the canonical
    /// V10 path under the current user's home.
    public let storePath: String

    /// Hard cap on the number of rows any single tool call may return. Caps
    /// honour the operator-supplied `limit` argument up to this value; values
    /// above it are silently clamped down. Default 1000.
    public let maxResultsHardCap: Int

    /// Hard cap on attachment bytes returned via `apple_mail_read_attachment`.
    /// Default 25MB. Larger attachments surface `attachmentTooLarge`.
    public let maxAttachmentBytes: Int

    /// Hard cap on `.emlx` body size accepted by the parser. Default 100MB.
    /// Lands in Phase A.2.
    public let maxMessageBytes: Int

    /// Hard cap on multipart MIME nesting depth in the `.emlx` parser.
    /// Default 32. Lands in Phase A.2.
    public let maxMultipartDepth: Int

    /// SQLite busy-timeout in milliseconds. Mail.app holds the database open
    /// in WAL mode; brief contention is normal. Default 200ms.
    public let sqliteBusyTimeoutMs: Int32

    /// Log verbosity. Errors are always emitted to `stderr`-equivalent; this
    /// gates info-level logs only.
    public let logLevel: LogLevel

    public enum LogLevel: String, Sendable {
        case quiet, info, debug
    }

    public init(
        storePath: String = MailBladeConfig.defaultStorePath,
        maxResultsHardCap: Int = 1000,
        maxAttachmentBytes: Int = 25 * 1024 * 1024,
        maxMessageBytes: Int = 100 * 1024 * 1024,
        maxMultipartDepth: Int = 32,
        sqliteBusyTimeoutMs: Int32 = 200,
        logLevel: LogLevel = .quiet
    ) throws {
        try Self.validate(storePath: storePath)
        self.storePath = storePath
        self.maxResultsHardCap = max(1, maxResultsHardCap)
        self.maxAttachmentBytes = max(1, maxAttachmentBytes)
        self.maxMessageBytes = max(1, maxMessageBytes)
        self.maxMultipartDepth = max(1, maxMultipartDepth)
        self.sqliteBusyTimeoutMs = max(0, sqliteBusyTimeoutMs)
        self.logLevel = logLevel
    }

    /// Canonical V10 path resolved against the current process's home directory.
    public static var defaultStorePath: String {
        let home = NSHomeDirectory()
        return "\(home)/Library/Mail/V10/MailData/Envelope Index"
    }

    /// Allowed path prefixes. Real Mail.app V10 is the only operational path;
    /// `/private/tmp/` is allowed exclusively to support fixture-based tests.
    static func allowedPrefixes() -> [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Library/Mail/V10/",
            "/private/tmp/",
            "/tmp/",  // macOS symlink for /private/tmp; allowed for symmetry
        ]
    }

    /// Validate `storePath`. Throws `MailBladeError.invalidStorePath` if the
    /// path falls outside the allowed prefixes.
    public static func validate(storePath: String) throws {
        // Reject path-traversal first — `..` segments would let a caller
        // sidestep the prefix check.
        if storePath.contains("..") {
            throw MailBladeError.invalidStorePath(path: storePath)
        }
        for prefix in allowedPrefixes() {
            if storePath.hasPrefix(prefix) {
                return
            }
        }
        throw MailBladeError.invalidStorePath(path: storePath)
    }
}
