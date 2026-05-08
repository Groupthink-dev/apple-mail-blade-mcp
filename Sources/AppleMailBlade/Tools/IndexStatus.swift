// IndexStatus.swift
//
// Handler for `apple_mail_index_status`. Returns the current
// `MailIndexHealth` snapshot so consuming skills can branch on
// freshness — e.g. "if `lag_rows > 100`, run a fast catch-up reindex
// before classifying."
//
// Read-only; no side effects. Returns `MailIndexHealth.dormant` when
// the harness hasn't wired a `MailFTS5QueryClient` (standalone-blade
// mode or pre-A.3b harness).

import Foundation
import MCP

public struct IndexStatusHandler: Sendable {

    /// Optional FTS5 query client. Nil in standalone-blade tests; the
    /// harness injects a real impl at construction time.
    public let fts5Client: (any MailFTS5QueryClient)?

    public init(fts5Client: (any MailFTS5QueryClient)?) {
        self.fts5Client = fts5Client
    }

    public func handle(arguments: [String: Value]?) async -> CallTool.Result {
        let health = await fts5Client?.indexHealth() ?? .dormant
        return makeResult(payload: health)
    }
}
