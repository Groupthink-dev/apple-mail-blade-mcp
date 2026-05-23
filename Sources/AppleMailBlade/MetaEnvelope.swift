// MetaEnvelope.swift
//
// DD-338 Phase C Wave 5 — canonical `_meta:` envelope helper for the Swift
// blade-mcp class. Establishes precedent for all future first-party Swift
// blades. Duplicated byte-equivalent across `apple-mail-blade-mcp` and
// `apple-notes-blade-mcp` per DD-240 invariant #8 (no cross-blade-mcp deps).
//
// Wire shape:
//
//     <existing-JSON-payload>
//
//     _meta: {"matched_total": 42, "returned": 10, "filtered_by": [...], "latency_ms": 87}
//
// Required fields: `matched_total: Int`, `returned: Int`, `filtered_by: [String]`,
// `latency_ms: Int`. Optional fields (`redactions`, `next_cursor`, `error_notes`)
// are OMITTED when empty/nil per Wave 3 OQ-1 ratification.
//
// Cross-language byte-non-equivalence with Python (`json.dumps(separators=
// (", ", ": "))`) and TS (`JSON.stringify`) is ACCEPTED per Wave 5 OQ-1
// ratification — the assembler regex `\n\n_meta: (\{.*\})$` parses the JSON
// object, it does not byte-hash the line. See DEVFU
// `2026-05-23-meta-envelope-byte-equivalence-cross-language`.
//
// Reference helpers:
//   - Python: `gmail-blade-mcp/src/gmail_blade_mcp/server.py` (_format_meta_envelope)
//   - TS:     `cloudflare-blade-mcp/src/utils/meta.ts` (formatMetaLine)

import CryptoKit
import Foundation
import MCP

// MARK: - Envelope value type

/// Canonical `_meta:` envelope value. `Sendable` for actor reach.
///
/// Construction discipline: callers pre-sort `filteredBy` alphabetically for
/// hash reproducibility (the helper does NOT re-sort on emit — sort site is
/// the caller's contract per Wave 3 ratification). Optional arrays passed as
/// `nil` OR `[]` are omitted from the emitted JSON.
public struct MetaEnvelope: Sendable {
    public let matchedTotal: Int
    public let returned: Int
    public let filteredBy: [String]
    public let latencyMs: Int
    public let redactions: [String]?
    public let nextCursor: String?
    public let errorNotes: [String]?

    public init(
        matchedTotal: Int,
        returned: Int,
        filteredBy: [String],
        latencyMs: Int,
        redactions: [String]? = nil,
        nextCursor: String? = nil,
        errorNotes: [String]? = nil
    ) {
        self.matchedTotal = matchedTotal
        self.returned = returned
        self.filteredBy = filteredBy
        self.latencyMs = latencyMs
        self.redactions = redactions
        self.nextCursor = nextCursor
        self.errorNotes = errorNotes
    }
}

// MARK: - Wire formatting

/// Format a `_meta:` envelope line. Single-line JSON. The caller MUST prepend
/// `\n\n` when appending to an existing payload (canonical separator).
///
/// Optional fields (`redactions`, `next_cursor`, `error_notes`) are omitted
/// when empty/nil. JSON top-level keys are sorted alphabetically via
/// `JSONEncoder.OutputFormatting.sortedKeys` for byte-reproducibility within
/// the Swift implementation. (Cross-language byte equality with Python+TS is
/// not guaranteed — see file header.)
public func formatMetaLine(_ meta: MetaEnvelope) -> String {
    var shadow = MetaEnvelopeShadow(
        matched_total: meta.matchedTotal,
        returned: meta.returned,
        filtered_by: meta.filteredBy,
        latency_ms: meta.latencyMs
    )
    if let redactions = meta.redactions, !redactions.isEmpty {
        shadow.redactions = redactions
    }
    if let nextCursor = meta.nextCursor {
        shadow.next_cursor = nextCursor
    }
    if let errorNotes = meta.errorNotes, !errorNotes.isEmpty {
        shadow.error_notes = errorNotes
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data: Data
    do {
        data = try encoder.encode(shadow)
    } catch {
        // Encoding a struct of primitives + arrays-of-strings cannot fail in
        // practice; fall back to a minimal stub on the off chance.
        return #"_meta: {"matched_total":0,"returned":0,"filtered_by":[],"latency_ms":0}"#
    }
    let json = String(data: data, encoding: .utf8) ?? "{}"
    return "_meta: " + json
}

/// Append a `_meta:` envelope line to an existing payload using the canonical
/// `\n\n` separator. Use at every Track-promoted tool-handler site; do NOT
/// inline the concatenation.
public func appendMeta(_ payload: String, _ metaLine: String) -> String {
    return "\(payload)\n\n\(metaLine)"
}

/// Shadow struct for `JSONEncoder` — uses snake_case property names so the
/// emitted keys match the wire-shape spec without per-key `CodingKeys` boilerplate.
/// Top-level key ordering is irrelevant because `JSONEncoder.OutputFormatting`
/// `.sortedKeys` is applied on emit.
private struct MetaEnvelopeShadow: Encodable {
    let matched_total: Int  // swiftlint:disable:this identifier_name
    let returned: Int
    let filtered_by: [String]  // swiftlint:disable:this identifier_name
    let latency_ms: Int  // swiftlint:disable:this identifier_name
    var redactions: [String]?
    var next_cursor: String?  // swiftlint:disable:this identifier_name
    var error_notes: [String]?  // swiftlint:disable:this identifier_name
}

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
