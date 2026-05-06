import Foundation

/// Resolves the on-disk path of a `.emlx` file given a message ROWID.
///
/// Apple's V10 layout stores message bodies under
/// `~/Library/Mail/V10/<accountUUID>/<mailbox>.mbox/<mboxUUID>/Data/<dir-tree>/Messages/<msgID>.emlx`.
/// The `<dir-tree>` is a sharding scheme based on the message ID's digits;
/// the exact form differs across macOS versions.
///
/// Rather than encode the sharding scheme (which would break silently if
/// Apple changes it), v0.1.0 does a recursive scan under the configured
/// Mail prefix on first request and caches the result. Subsequent lookups
/// hit the cache. The cache invalidates when the file no longer exists at
/// the cached path (e.g. after a Mail.app re-index).
public actor EMLXLocator {

    private let mailRoot: String
    private var cache: [Int64: String] = [:]

    /// Build a locator rooted at the directory containing `MailData/`. For
    /// a config pointing at `~/Library/Mail/V10/MailData/Envelope Index`,
    /// the root is `~/Library/Mail/V10/`. For test fixtures rooted under
    /// `/private/tmp/<uuid>/V10/MailData/Envelope Index`, the root is
    /// `/private/tmp/<uuid>/V10/`.
    public init(config: MailBladeConfig) {
        let envPath = config.storePath
        // Strip trailing `MailData/Envelope Index` to get the V10 root.
        let mailDataDir = (envPath as NSString).deletingLastPathComponent  // .../MailData
        self.mailRoot = (mailDataDir as NSString).deletingLastPathComponent  // .../V10
    }

    /// Resolve the absolute filesystem path of `<messageID>.emlx`. Returns
    /// `nil` if the file cannot be located under the configured root.
    public func locate(messageID: Int64) -> String? {
        if let cached = cache[messageID], FileManager.default.fileExists(atPath: cached) {
            return cached
        }
        let needle = "\(messageID).emlx"
        if let found = scan(root: mailRoot, needle: needle) {
            cache[messageID] = found
            return found
        }
        return nil
    }

    /// Resolve the `Attachments/` subtree path for a given message ID.
    /// Returns `nil` if the message can't be located. The returned directory
    /// is `<mboxUUID>/Attachments/<messageID>/` — caller walks within it.
    public func attachmentsRoot(messageID: Int64) -> String? {
        guard let emlxPath = locate(messageID: messageID) else { return nil }
        // From `<mbox>/<mboxUUID>/Data/<dir-tree>/Messages/<id>.emlx`, walk up
        // to `<mboxUUID>/`, then descend into `Attachments/<id>/`.
        var dir = (emlxPath as NSString).deletingLastPathComponent  // Messages/
        while !dir.isEmpty, dir != "/",
            !FileManager.default.fileExists(
                atPath: "\(dir)/Attachments"
            )
        {
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        let attachDir = "\(dir)/Attachments/\(messageID)"
        if FileManager.default.fileExists(atPath: attachDir) {
            return attachDir
        }
        return nil
    }

    /// Reset the cache. Useful after Mail.app reorganises its store; tests
    /// also use this between fixtures.
    public func reset() {
        cache.removeAll()
    }

    // MARK: - Internal scan

    private func scan(root: String, needle: String) -> String? {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == needle {
                return url.path
            }
        }
        return nil
    }
}
