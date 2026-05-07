import Foundation

/// Resolves the on-disk path of a `.emlx` file given a message ROWID.
///
/// Apple's V10 layout stores message bodies under
/// `~/Library/Mail/V10/<accountUUID>/<mailbox>.mbox/<mboxUUID>/Data/<dir-tree>/Messages/<msgID>.emlx`.
/// The `<dir-tree>` is a sharding scheme based on the message ID's digits;
/// the exact form differs across macOS versions.
///
/// ## v0.1.1 — hinted lookup
///
/// v0.1.0 did an unbounded recursive scan of `<V10>` for every lookup. On
/// real corpora (138k messages, 40 mailboxes, gigabytes of attachments)
/// this exceeded 60s per call and made the four `.emlx`-touching tools
/// unusable.
///
/// v0.1.1 adds a `MailboxHint` carrying the message's mailbox URL. Real
/// V10 stores `mailboxes.url` in the canonical form
/// `imap://<accountUUID>/<urlEncodedMailboxName>` — the host is the Mail
/// account UUID directly, and the path is the mailbox name. This maps
/// 1:1 to the on-disk subtree at
/// `<V10>/<accountUUID>/<mailboxName>.mbox/`. With the hint, the scan is
/// bounded to that single mailbox subtree (typically <2s on real corpora,
/// ms on subsequent lookups via the per-mailbox cache).
///
/// Robust fallback: if the hint can't be resolved (e.g. the URL host
/// doesn't match an on-disk account dir, which can happen in test
/// fixtures), the locator falls back to a **pruned** full-tree scan that
/// skips `Attachments/` subtrees — by far the largest space-consumer on
/// most users' Mail folders.
public actor EMLXLocator {

    private let mailRoot: String

    /// Per-message resolved `.emlx` path cache. Survives across calls.
    private var cache: [Int64: String] = [:]

    /// Per-mailbox resolved on-disk subtree cache, populated by
    /// `subtreePath(for:)`. Avoids repeated URL parsing + directory
    /// existence checks for back-to-back lookups in the same mailbox.
    private var mailboxSubtreeCache: [Int64: String] = [:]

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
    ///
    /// Pass a `MailboxHint` when known (preferred — bounds the scan to a
    /// single mailbox subtree). Without a hint, falls back to a pruned
    /// full-tree scan.
    public func locate(messageID: Int64, hint: MailboxHint? = nil) -> String? {
        if let cached = cache[messageID], FileManager.default.fileExists(atPath: cached) {
            return cached
        }
        let needle = "\(messageID).emlx"

        // Hinted fast path — bounded to one mailbox subtree.
        if let hint = hint, let scoped = subtreePath(for: hint) {
            if let found = scan(root: scoped, needle: needle) {
                cache[messageID] = found
                return found
            }
            // Hint resolved to a subtree but the file isn't there. Fall
            // through to the full-tree scan rather than returning nil —
            // a message may live in a different mailbox than the hint
            // suggests if Mail has reindexed since the index row was read.
        }

        // Pruned full-tree fallback. Skips Attachments/ subtrees so the
        // walk is bounded by Messages/ tree size, not total file count.
        if let found = scan(root: mailRoot, needle: needle) {
            cache[messageID] = found
            return found
        }
        return nil
    }

    /// Resolve the `Attachments/` subtree path for a given message ID.
    /// Returns `nil` if the message can't be located. The returned directory
    /// is `<mboxUUID>/Attachments/<messageID>/` — caller walks within it.
    public func attachmentsRoot(messageID: Int64, hint: MailboxHint? = nil) -> String? {
        guard let emlxPath = locate(messageID: messageID, hint: hint) else { return nil }
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
        mailboxSubtreeCache.removeAll()
    }

    // MARK: - Internal: hint resolution

    /// Resolve the on-disk subtree for a mailbox hint, if possible.
    /// Returns the absolute path to `<accountUUID>/<mailboxName>.mbox/`,
    /// or nil if neither the canonical layout nor a top-level scan locate
    /// a matching `.mbox` directory.
    ///
    /// **Real V10 fast path.** URL = `imap://<accountUUID>/<urlEncodedName>`
    /// → on-disk `<root>/<accountUUID>/<decodedName>.mbox/`. One stat call.
    ///
    /// **Slow path (test fixtures, edge URLs).** Iterate top-level account
    /// dirs (typically <10) looking for any with a `<decodedName>.mbox/`
    /// child. Bounded by account count.
    private func subtreePath(for hint: MailboxHint) -> String? {
        if let cached = mailboxSubtreeCache[hint.mailboxID] {
            return cached
        }
        guard let mailboxName = decodedLastPathComponent(of: hint.url) else {
            return nil
        }
        let fm = FileManager.default

        // Fast path — URL host == accountUUID, last path == mailbox name.
        if let host = host(of: hint.url) {
            let candidate = "\(mailRoot)/\(host)/\(mailboxName).mbox"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                mailboxSubtreeCache[hint.mailboxID] = candidate
                return candidate
            }
        }

        // Slow path — scan top-level account dirs.
        guard let accounts = try? fm.contentsOfDirectory(atPath: mailRoot) else {
            return nil
        }
        for account in accounts {
            let candidate = "\(mailRoot)/\(account)/\(mailboxName).mbox"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                mailboxSubtreeCache[hint.mailboxID] = candidate
                return candidate
            }
        }
        return nil
    }

    /// Extract the URL host (account UUID for real V10) without using
    /// `URL.host`, which percent-decodes and rejects some shapes.
    /// `imap://CBB15DC8.../INBOX` → `CBB15DC8...`
    /// `imap://piers%40mm.st@imap.fastmail.com/INBOX` → `imap.fastmail.com`
    /// (latter handled because URL parser strips userinfo correctly).
    private func host(of url: String) -> String? {
        // `URL` is permissive enough for IMAP/POP/Exchange/local schemes
        // we care about; host extraction works without explicit decoding.
        guard let parsed = URL(string: url), let h = parsed.host else { return nil }
        return h.isEmpty ? nil : h
    }

    /// Last URL path component, percent-decoded. Returns nil for empty
    /// or pathless URLs. URL paths are commonly multi-segment for nested
    /// IMAP folders (e.g. `local://localmac/On%20My%20Mac/Old%20Stuff` →
    /// last component `Old Stuff`).
    private func decodedLastPathComponent(of url: String) -> String? {
        // Avoid `URL.lastPathComponent` because it strips trailing slashes
        // and can be surprising on schemes without authority. Hand-parse:
        // find the path portion (after `://<authority>`) and split on `/`.
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let afterScheme = url[schemeEnd.upperBound...]
        guard let pathStart = afterScheme.firstIndex(of: "/") else { return nil }
        let path = afterScheme[afterScheme.index(after: pathStart)...]
        guard !path.isEmpty else { return nil }
        // Last segment after the final slash.
        if let lastSlash = path.lastIndex(of: "/") {
            let suffix = path[path.index(after: lastSlash)...]
            let raw = String(suffix)
            return raw.isEmpty ? nil : (raw.removingPercentEncoding ?? raw)
        }
        let raw = String(path)
        return raw.isEmpty ? nil : (raw.removingPercentEncoding ?? raw)
    }

    // MARK: - Internal: scan

    /// Recursive scan of `root` for a file named exactly `needle`. Prunes
    /// `Attachments/` subtrees because they cannot contain `.emlx` files
    /// and are by far the largest space-consumer on most users' Mail
    /// folders (image attachments, multipart bodies, etc).
    private func scan(root: String, needle: String) -> String? {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return nil
        }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            // Prune subtrees that can't contain `<id>.emlx`. `Attachments/`
            // dwarfs the Messages/ tree on real corpora; skipping it cuts
            // the walk by 1-2 orders of magnitude.
            if name == "Attachments" {
                enumerator.skipDescendants()
                continue
            }
            if name == needle {
                return url.path
            }
        }
        return nil
    }
}

/// Locator hint carrying the mailbox URL for the requested message.
/// Pass when known to bound the `.emlx` scan to a single mailbox subtree.
public struct MailboxHint: Sendable, Equatable {
    public let mailboxID: Int64
    public let url: String

    public init(mailboxID: Int64, url: String) {
        self.mailboxID = mailboxID
        self.url = url
    }
}
