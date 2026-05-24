// MetaHelpers.swift
//
// DD-338 Phase C Wave 5 — blade-local helpers that complement the canonical
// `MCPHelpers` module (SPM dep at
// https://github.com/Groupthink-dev/stallari-mcp-helpers-swift). The previous
// Sources/AppleMailBlade/MetaEnvelope.swift hand-rolled the entire envelope
// surface; it was deleted when the canonical lib shipped (v0.1.0) and the
// blade migrated onto the SPM dep. This file retains only the two helpers
// that are NOT part of the canonical surface:
//
//   - `Duration.toMilliseconds()` — convert `ContinuousClock.Duration` to Int
//     milliseconds for `MetaEnvelope.latencyMs` (canonical lib leaves clock
//     marshalling to the caller).
//   - `metaQueryDigest(_:)` — SHA-256 short-digest of a verbatim query string
//     for `filtered_by` `query=` audit entries. Blade-domain helper (search
//     tools use it); not generic enough for the canonical lib.
//
// All envelope construction, formatting, and appending now flows through
// `MCPHelpers.MetaEnvelope`, `MCPHelpers.formatMetaLine`, and
// `MCPHelpers.appendMeta`.

import CryptoKit
import Foundation

// MARK: - Latency timing

extension Duration {
    /// Convert a `ContinuousClock.Duration` (or any `Duration`) to integer
    /// milliseconds. Truncates sub-millisecond fractions. Used to populate
    /// `MetaEnvelope.latencyMs`.
    public func toMilliseconds() -> Int {
        let comps = self.components
        // attoseconds = 1e-18 s; 1 ms = 1e-3 s = 1e15 attoseconds.
        let msFromSeconds = comps.seconds * 1000
        let msFromAttoseconds = comps.attoseconds / 1_000_000_000_000_000
        return Int(msFromSeconds + msFromAttoseconds)
    }
}

// MARK: - Query digest

/// Compute a SHA-256-based 12-character digest of a query string, suitable for
/// `filtered_by` `query=` audit values. Privacy-safe + token-bound +
/// collision-resistant within session window. Mirrors W3 OQ-6 ratification for
/// `cf_d1_query`. The digest is non-reversible — the assembler audit trail
/// records that a search was performed without recording the verbatim query
/// bytes.
public func metaQueryDigest(_ query: String) -> String {
    let data = Data(query.utf8)
    let digest = SHA256.hash(data: data)
    let base64 = Data(digest).base64EncodedString()
    // Strip non-alphanumeric chars (`+`, `/`, `=`) to keep the audit value
    // path-safe and grep-friendly, then take the first 12 characters.
    let stripped = base64.filter { $0.isLetter || $0.isNumber }
    return String(stripped.prefix(12))
}
