// MailFTS5QueryClient.swift
//
// Narrow query-time DI surface that the harness implements (via
// `MailFTS5QueryClientImpl` in stallari-harness) and the blade
// consumes (via `MailStore.searchMessages`'s routing decision).
//
// Two-way design discipline:
//
// 1. The protocol surface is minimal — `isHealthyForQuery`,
//    `searchFTS5(query:limit:)`, `indexHealth()`. Filters (account /
//    mailbox / since) apply at the SQL join-back stage inside
//    `MailStore.searchMessagesFTS5`, NOT inside the FTS5 query path —
//    keeps the FTS5 path narrow and tied to the single
//    `mail_messages_fts5` virtual-table query.
//
// 2. The blade ships standalone (no StallariKit dependency) — the
//    real `MailFTS5QueryClientImpl` lives in stallari-harness and
//    holds a SQLCipher-keyed readonly `Connection` to
//    `local-corpus-index.db`. The blade only sees the protocol.
//
// Reindex control flow (out of band): `apple_mail_reindex` tool
// posts a `Notification.Name.mailIndexReindexRequested` notification
// with `force: Bool` userInfo; the harness wiring observes and
// forwards to `IndexCoordinator.requestReindex(blade:force:)`. The
// query-time protocol stays free of control-surface concerns.
//
// See [[DD-256]] §A.4 + implementation plan §A.4.

import Foundation

/// Health snapshot consumed by `apple_mail_index_status`. Mirrors the
/// shape of `/api/health` `local_corpus_index.blades.mail` so consuming
/// skills can branch on freshness uniformly across surfaces.
public struct MailIndexHealth: Sendable, Codable, Equatable {
    public let consented: Bool
    public let registered: Bool
    public let storeOpen: Bool
    public let watermarkROWID: Int64
    public let lagRows: Int64
    public let lastIndexedAt: String?
    public let lastFullReindexAt: String?
    public let pendingFullReindex: Bool
    public let onBatteryBlocked: Bool
    public let errorCount: Int64
    public let lastError: String?

    public init(
        consented: Bool,
        registered: Bool,
        storeOpen: Bool,
        watermarkROWID: Int64,
        lagRows: Int64,
        lastIndexedAt: String?,
        lastFullReindexAt: String?,
        pendingFullReindex: Bool,
        onBatteryBlocked: Bool,
        errorCount: Int64,
        lastError: String?
    ) {
        self.consented = consented
        self.registered = registered
        self.storeOpen = storeOpen
        self.watermarkROWID = watermarkROWID
        self.lagRows = lagRows
        self.lastIndexedAt = lastIndexedAt
        self.lastFullReindexAt = lastFullReindexAt
        self.pendingFullReindex = pendingFullReindex
        self.onBatteryBlocked = onBatteryBlocked
        self.errorCount = errorCount
        self.lastError = lastError
    }

    /// `MailIndexHealth` value for "blade unavailable" — the consent
    /// flag is in the user-config layer so we can read it; everything
    /// else is dormant.
    public static let dormant: MailIndexHealth = MailIndexHealth(
        consented: false,
        registered: false,
        storeOpen: false,
        watermarkROWID: 0,
        lagRows: 0,
        lastIndexedAt: nil,
        lastFullReindexAt: nil,
        pendingFullReindex: false,
        onBatteryBlocked: false,
        errorCount: 0,
        lastError: nil
    )

    enum CodingKeys: String, CodingKey {
        case consented, registered
        case storeOpen = "store_open"
        case watermarkROWID = "watermark_rowid"
        case lagRows = "lag_rows"
        case lastIndexedAt = "last_indexed_at"
        case lastFullReindexAt = "last_full_reindex_at"
        case pendingFullReindex = "pending_full_reindex"
        case onBatteryBlocked = "on_battery_blocked"
        case errorCount = "error_count"
        case lastError = "last_error"
    }
}

/// Query-time client for the FTS5 sidecar. Implemented in
/// stallari-harness (`MailFTS5QueryClientImpl`) — the blade consumes
/// the protocol via dependency injection at construction time.
///
/// Methods are `async` so the impl can route through actor-isolated
/// access to the shared `local-corpus-index.db` readonly connection.
public protocol MailFTS5QueryClient: Sendable {

    /// `true` when an FTS5 query is safe to run instead of LIKE. False
    /// when the index is missing, behind by >100 rows, or rebuilding —
    /// `MailStore.searchMessages` falls back to the LIKE path.
    var isHealthyForQuery: Bool { get async }

    /// Run the FTS5 query and return matching ROWIDs in
    /// upstream-store ROWID order. The caller joins back to the live
    /// `messages` table to apply filters and assemble result shape.
    /// `query` is passed to FTS5 with `MATCH` — callers must escape /
    /// quote special tokens before calling.
    func searchFTS5(query: String, limit: Int) async throws -> [Int64]

    /// Current health snapshot for `apple_mail_index_status`. Returns
    /// `MailIndexHealth.dormant` when the index hasn't materialised
    /// yet.
    func indexHealth() async -> MailIndexHealth
}

extension Notification.Name {
    /// Posted by the `apple_mail_reindex` tool handler. The harness
    /// wiring (in `AppleMailBladeWiring`) observes and forwards to
    /// `IndexCoordinator.requestReindex(blade:force:)`. Payload:
    /// `userInfo["force"]: Bool` — when `true`, bypass the
    /// AC-power gate.
    public static let mailIndexReindexRequested = Notification.Name(
        "ai.stallari.local_corpus_index.mail.reindex_requested"
    )
}
