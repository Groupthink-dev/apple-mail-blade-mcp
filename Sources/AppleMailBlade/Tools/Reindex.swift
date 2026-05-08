// Reindex.swift
//
// Handler for `apple_mail_reindex`. Posts a request notification and
// returns immediately — actual reindex runs out of band on the
// harness `IndexCoordinator`'s poll task.
//
// `force: Bool` — `true` bypasses the AC-power gate (useful when the
// user clicks "Reindex now" in the Settings tile and is willing to
// burn battery for it). Default `false`: indexer queues the rebuild
// in `pending_full_reindex` and drains on the next AC-on tick.
//
// Status is observable via `apple_mail_index_status` (returns
// `MailIndexHealth` with `pending_full_reindex` reflected).

import Foundation
import MCP

public struct ReindexHandler: Sendable {

    public init() {}

    public func handle(arguments: [String: Value]?) async -> CallTool.Result {
        let force: Bool
        switch arguments?["force"] {
        case .bool(let value): force = value
        case .none: force = false
        default:
            return errorResult(.internalError("`force` must be a boolean if provided"))
        }

        // Post the request via DistributedNotificationCenter (DD-256
        // §A.5) so the SwiftUI Settings tile in the app process and
        // the harness observer in the daemon process see the same
        // event. The tool itself runs inside the daemon, so a local
        // post would also work for that path — but the cross-process
        // case (the SwiftUI "Reindex now" button) needs distributed,
        // and using one channel keeps the substrate simple.
        //
        // Standalone-blade mode (no harness wired): nobody subscribes.
        // The tool returns an "accepted" result anyway; consumers that
        // depend on the reindex actually running should poll
        // `apple_mail_index_status` and confirm `pending_full_reindex`
        // toggled.
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(
            .mailIndexReindexRequested,
            object: nil,
            userInfo: ["force": force],
            deliverImmediately: true
        )
        #else
        NotificationCenter.default.post(
            name: .mailIndexReindexRequested,
            object: nil,
            userInfo: ["force": force]
        )
        #endif

        struct Accepted: Codable, Sendable {
            let accepted: Bool
            let force: Bool
        }
        return makeResult(payload: Accepted(accepted: true, force: force))
    }
}
