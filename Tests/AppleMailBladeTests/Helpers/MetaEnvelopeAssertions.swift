// MetaEnvelopeAssertions.swift
//
// DD-338 Phase C Wave 5 — test-side helpers for parsing + asserting the
// canonical `_meta:` envelope. Duplicated byte-equivalent across
// `apple-mail-blade-mcp` and `apple-notes-blade-mcp` per DD-240 invariant #8.
//
// These helpers are the natural plug-in points for DD-333 Phase C conformance
// harness when it extends to Swift.

import Foundation
import MCP
import XCTest

/// Extract the raw text payload from a `CallTool.Result` — concatenates every
/// `.text` content item. Mirrors the `extractText` pattern used in
/// `ToolRegistryTests`.
func extractText(from result: CallTool.Result) -> String {
    var out = ""
    for item in result.content {
        if case .text(let text, _, _) = item {
            out += text
        }
    }
    return out
}

/// Parse the trailing `_meta:` envelope from a tool result text. Returns nil
/// if no envelope is present (legacy minimal tool).
///
/// Accepts the canonical wire shape: `<payload>\n\n_meta: {...}`. Uses
/// `JSONSerialization` for the inner JSON parse so the helper has zero
/// dependency on internal types.
func parseMeta(from text: String) -> [String: Any]? {
    guard let range = text.range(of: "\n\n_meta: ", options: .backwards) else {
        return nil
    }
    let jsonStart = range.upperBound
    let jsonString = String(text[jsonStart...])
    guard let data = jsonString.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// Return the JSON payload portion of a tool-result text (everything before
/// the trailing `\n\n_meta:` envelope). When no envelope is present, returns
/// the full text unchanged.
func payloadJSON(from text: String) -> String {
    guard let range = text.range(of: "\n\n_meta: ", options: .backwards) else {
        return text
    }
    return String(text[..<range.lowerBound])
}

/// Assert that a parsed `_meta` envelope has the canonical required keys
/// (`matched_total`, `returned`, `filtered_by`, `latency_ms`) with the right
/// value-shape types.
func XCTAssertMetaShape(
    _ meta: [String: Any]?,
    file: StaticString = #file,
    line: UInt = #line
) {
    guard let meta else {
        XCTFail("expected _meta envelope, got nil", file: file, line: line)
        return
    }
    XCTAssertNotNil(meta["matched_total"] as? Int, "matched_total missing or wrong type", file: file, line: line)
    XCTAssertNotNil(meta["returned"] as? Int, "returned missing or wrong type", file: file, line: line)
    XCTAssertNotNil(meta["filtered_by"] as? [String], "filtered_by missing or wrong type", file: file, line: line)
    XCTAssertNotNil(meta["latency_ms"] as? Int, "latency_ms missing or wrong type", file: file, line: line)
}
