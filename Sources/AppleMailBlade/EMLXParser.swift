import Foundation

/// Hand-rolled `.emlx` parser. Three layers:
///
/// 1. **`.emlx` envelope** — Apple wraps each message as
///    ```
///    <ascii-decimal-byte-count>\n
///    <N bytes of RFC822>
///    <binary-plist trailer>
///    ```
///    The plist carries Apple-side flags (read/flagged/junk classification).
///    v0.1.0 ignores it; we slice out the RFC822 payload by reading the
///    leading length prefix.
///
/// 2. **RFC822 headers** — line-folded `Header: value` block terminated by a
///    blank line. Header values may be RFC2047 encoded-words
///    (`=?charset?Q-or-B?text?=`) which we decode where they appear.
///
/// 3. **MIME bodies** — `Content-Type: multipart/*; boundary="..."` triggers
///    a recursive walker. Honours `Content-Transfer-Encoding`
///    (base64 / quoted-printable / 7bit / 8bit / binary). Returns the first
///    `text/plain` part as `bodyText`, the first `text/html` part as
///    `bodyHTML` (when requested), and enumerates non-text parts as
///    attachments.
///
/// **Hardening:** bounded multipart recursion (default 32), max overall
/// message size (default 100MB). Both come from the supplied
/// `MailBladeConfig`. Errors carry `messageID` only — never body content.
public struct EMLXParser: Sendable {

    public struct Result: Sendable {
        public let headers: [String: [String]]
        public let bodyText: String?
        public let bodyHTML: String?
        public let attachments: [AttachmentMeta]
    }

    public let config: MailBladeConfig

    public init(config: MailBladeConfig) {
        self.config = config
    }

    /// Parse a single `.emlx` payload.
    ///
    /// - Parameters:
    ///   - data: raw bytes from disk.
    ///   - messageID: passed through into errors for correlation; never logged in content.
    ///   - includeHTML: when true, the first `text/html` part is decoded into `bodyHTML`.
    public func parse(_ data: Data, messageID: Int64, includeHTML: Bool) throws -> Result {
        guard data.count <= config.maxMessageBytes else {
            throw MailBladeError.decodeFailure(
                messageID: messageID,
                reason: "message exceeds maxMessageBytes (\(data.count) > \(config.maxMessageBytes))"
            )
        }

        let rfc822 = try sliceRFC822(data, messageID: messageID)
        let (headers, bodyStart) = try parseHeaders(rfc822, messageID: messageID)

        let bodyData = rfc822.subdata(in: bodyStart..<rfc822.count)

        let walker = MIMEWalker(
            config: config,
            messageID: messageID,
            includeHTML: includeHTML
        )
        let walked = try walker.walk(headers: headers, body: bodyData, depth: 0)

        return Result(
            headers: decodeHeadersForDisplay(headers),
            bodyText: walked.bodyText,
            bodyHTML: walked.bodyHTML,
            attachments: walked.attachments(messageID: messageID)
        )
    }

    // MARK: - Layer 1: envelope (length-prefix slice)

    /// Slice the leading length-prefix and return only the RFC822 payload.
    /// `.emlx` files start with an ASCII decimal byte count followed by
    /// either a single newline (`\n`) or CRLF, then the RFC822 payload.
    private func sliceRFC822(_ data: Data, messageID: Int64) throws -> Data {
        // The prefix is a small number of ASCII digits — read up to the first
        // newline. Apple usually writes `\n` (LF), but tolerate CRLF.
        var i = 0
        while i < min(data.count, 32) {
            let b = data[i]
            if b == 0x0A { break }
            if !(b >= 0x30 && b <= 0x39) && b != 0x0D {
                throw MailBladeError.decodeFailure(
                    messageID: messageID,
                    reason: "non-digit in length prefix at offset \(i)"
                )
            }
            i += 1
        }
        guard i < data.count, data[i] == 0x0A else {
            throw MailBladeError.decodeFailure(
                messageID: messageID,
                reason: "no newline terminator after length prefix"
            )
        }
        let prefixBytes = data.subdata(in: 0..<i)
        let stripped = prefixBytes.filter { $0 != 0x0D }  // Drop CR if CRLF
        guard let prefixStr = String(data: stripped, encoding: .ascii),
            let length = Int(prefixStr.trimmingCharacters(in: .whitespaces))
        else {
            throw MailBladeError.decodeFailure(
                messageID: messageID,
                reason: "length prefix not parseable as decimal"
            )
        }
        let payloadStart = i + 1
        let payloadEnd = payloadStart + length
        guard payloadEnd <= data.count else {
            throw MailBladeError.decodeFailure(
                messageID: messageID,
                reason: "length prefix \(length) exceeds remaining bytes (\(data.count - payloadStart))"
            )
        }
        return data.subdata(in: payloadStart..<payloadEnd)
    }

    // MARK: - Layer 2: RFC822 headers

    /// Parse line-folded headers. Returns the header map (name lowercased,
    /// values in original case) and the byte offset where the body starts
    /// (just past the blank-line separator).
    private func parseHeaders(
        _ data: Data, messageID: Int64
    )
        throws -> ([String: [String]], Int)
    {
        var headers: [String: [String]] = [:]
        var current = ""
        var i = 0
        // Walk lines. A header continuation is a line beginning with whitespace.
        while i < data.count {
            // Find next \n
            var lineEnd = i
            while lineEnd < data.count, data[lineEnd] != 0x0A {
                lineEnd += 1
            }
            // Slice line (without \n).
            let lineData = data.subdata(in: i..<lineEnd)
            // Strip trailing \r if CRLF.
            let trimmed: Data = {
                if lineData.last == 0x0D {
                    return lineData.subdata(in: 0..<(lineData.count - 1))
                }
                return lineData
            }()
            guard
                let line = String(data: trimmed, encoding: .utf8)
                    ?? String(data: trimmed, encoding: .isoLatin1)
            else {
                throw MailBladeError.decodeFailure(
                    messageID: messageID,
                    reason: "header line at offset \(i) is not UTF-8/Latin-1"
                )
            }
            // Empty line ends the header block.
            if line.isEmpty {
                // Flush current.
                if !current.isEmpty {
                    appendHeader(current, into: &headers)
                    current = ""
                }
                let bodyStart = lineEnd + 1
                return (headers, min(bodyStart, data.count))
            }
            // Continuation lines start with whitespace.
            if line.first == " " || line.first == "\t" {
                if current.isEmpty {
                    throw MailBladeError.decodeFailure(
                        messageID: messageID,
                        reason: "header continuation without prior header"
                    )
                }
                current += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                // New header — flush previous.
                if !current.isEmpty {
                    appendHeader(current, into: &headers)
                }
                current = line
            }
            i = lineEnd + 1
        }
        // Reached EOF without blank line — body is empty.
        if !current.isEmpty {
            appendHeader(current, into: &headers)
        }
        return (headers, data.count)
    }

    private func appendHeader(_ raw: String, into headers: inout [String: [String]]) {
        guard let colonIdx = raw.firstIndex(of: ":") else { return }
        let name = String(raw[..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(raw[raw.index(after: colonIdx)...])
            .trimmingCharacters(in: .whitespaces)
        headers[name, default: []].append(value)
    }

    /// Apply RFC2047 decoding to display-relevant headers (subject, from, to,
    /// cc) so the headers map returned to consumers is human-readable.
    private func decodeHeadersForDisplay(
        _ headers: [String: [String]]
    )
        -> [String: [String]]
    {
        var out: [String: [String]] = [:]
        for (name, values) in headers {
            switch name {
            case "subject", "from", "to", "cc", "bcc", "reply-to", "sender":
                out[name] = values.map { RFC2047.decode($0) }
            default:
                out[name] = values
            }
        }
        return out
    }

    // MARK: - Public single-decode helpers (exposed for tests)

    /// Parse a `Content-Type` header into media type + parameters.
    public static func parseContentType(_ raw: String) -> (mediaType: String, params: [String: String]) {
        var params: [String: String] = [:]
        let parts = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first else { return ("", [:]) }
        let mediaType = first.lowercased()
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            let k = String(p[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            var v = String(p[p.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // Strip surrounding double-quotes.
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            params[k] = v
        }
        return (mediaType, params)
    }
}

// MARK: - MIME walker

/// Recursive walker that decodes a single message body, splitting multipart
/// parts and selecting the first `text/plain` and (optionally) `text/html`
/// part as the message bodies. Non-text parts become attachments.
private struct MIMEWalker {
    let config: MailBladeConfig
    let messageID: Int64
    let includeHTML: Bool

    /// Mutable accumulator passed by reference through the recursive walk.
    final class Accumulator {
        var bodyText: String?
        var bodyHTML: String?
        var rawAttachments: [RawAttachment] = []

        struct RawAttachment {
            let filename: String?
            let mimeType: String?
            let contentID: String?
            let byteSize: Int
        }

        func attachments(messageID: Int64) -> [AttachmentMeta] {
            rawAttachments.enumerated().map { (offset, raw) in
                AttachmentMeta(
                    id: Int64(offset),
                    messageID: messageID,
                    filename: raw.filename,
                    mimeType: raw.mimeType,
                    contentID: raw.contentID,
                    byteSize: raw.byteSize
                )
            }
        }
    }

    func walk(headers: [String: [String]], body: Data, depth: Int) throws -> Accumulator {
        let acc = Accumulator()
        try walkRecursive(headers: headers, body: body, depth: depth, into: acc)
        return acc
    }

    private func walkRecursive(
        headers: [String: [String]], body: Data, depth: Int, into acc: Accumulator
    ) throws {
        guard depth <= config.maxMultipartDepth else {
            throw MailBladeError.decodeFailure(
                messageID: messageID,
                reason: "multipart nesting exceeds maxMultipartDepth (\(config.maxMultipartDepth))"
            )
        }

        let contentType = headers["content-type"]?.first ?? "text/plain"
        let (mediaType, params) = EMLXParser.parseContentType(contentType)
        let encoding = (headers["content-transfer-encoding"]?.first ?? "7bit")
            .lowercased().trimmingCharacters(in: .whitespaces)
        let disposition = headers["content-disposition"]?.first ?? ""
        let (dispToken, dispParams) = EMLXParser.parseContentType(disposition)

        if mediaType.hasPrefix("multipart/") {
            guard let boundary = params["boundary"], !boundary.isEmpty else {
                throw MailBladeError.decodeFailure(
                    messageID: messageID,
                    reason: "multipart \(mediaType) without boundary"
                )
            }
            let parts = splitMultipart(body, boundary: boundary)
            for partData in parts {
                let parser = EMLXParser(config: config)
                // Each part has its own headers — re-parse.
                let (partHeaders, partBodyStart) = try parser.parseHeadersInternal(
                    partData, messageID: messageID
                )
                let partBody = partData.subdata(in: partBodyStart..<partData.count)
                try walkRecursive(
                    headers: partHeaders,
                    body: partBody,
                    depth: depth + 1,
                    into: acc
                )
            }
            return
        }

        // Decoded leaf payload.
        let decoded = try decode(body: body, encoding: encoding)

        let isAttachment =
            dispToken == "attachment"
            || dispParams["filename"] != nil
            || params["name"] != nil

        if mediaType == "text/plain" && !isAttachment && acc.bodyText == nil {
            let text = textFromBytes(decoded, charset: params["charset"])
            acc.bodyText = text.isEmpty ? nil : text
            return
        }
        if mediaType == "text/html" && !isAttachment && includeHTML && acc.bodyHTML == nil {
            let text = textFromBytes(decoded, charset: params["charset"])
            acc.bodyHTML = text.isEmpty ? nil : text
            return
        }
        if mediaType == "text/html" && !isAttachment && !includeHTML {
            // Caller didn't request HTML — drop silently.
            return
        }
        // Attachment.
        let filename =
            dispParams["filename"]
            ?? params["name"]
        let contentID = headers["content-id"]?.first.map { stripAngleBrackets($0) }
        acc.rawAttachments.append(
            Accumulator.RawAttachment(
                filename: filename.map { RFC2047.decode($0) },
                mimeType: mediaType,
                contentID: contentID,
                byteSize: decoded.count
            )
        )
    }

    private func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let openMarker = "--\(boundary)"
        let closeMarker = "--\(boundary)--"
        guard let openData = openMarker.data(using: .utf8),
            let _ = closeMarker.data(using: .utf8)
        else { return [] }

        // Find each occurrence of `--boundary`. The delimiters are typically
        // at line starts; scan for the byte sequence preceded by newline (or
        // start of body).
        var parts: [Data] = []
        var cursor = 0
        var partStart: Int? = nil
        while cursor < body.count {
            if let range = rangeOfMarker(in: body, marker: openData, from: cursor) {
                if let s = partStart {
                    // Slice [s, range.lowerBound), trimming trailing CRLF.
                    var end = range.lowerBound
                    if end > s, body[end - 1] == 0x0A { end -= 1 }
                    if end > s, body[end - 1] == 0x0D { end -= 1 }
                    if end > s {
                        parts.append(body.subdata(in: s..<end))
                    }
                }
                let after = range.upperBound
                // Check if closing marker (--boundary--).
                let closeRangeStart = range.lowerBound
                let closeLen = closeMarker.utf8.count
                if closeRangeStart + closeLen <= body.count {
                    let probe = body.subdata(in: closeRangeStart..<(closeRangeStart + closeLen))
                    if String(data: probe, encoding: .utf8) == closeMarker {
                        // No more parts.
                        return parts
                    }
                }
                // Skip the boundary marker line.
                var afterLine = after
                while afterLine < body.count, body[afterLine] != 0x0A {
                    afterLine += 1
                }
                if afterLine < body.count { afterLine += 1 }
                partStart = afterLine
                cursor = afterLine
            } else {
                break
            }
        }
        if let s = partStart, s < body.count {
            parts.append(body.subdata(in: s..<body.count))
        }
        return parts
    }

    private func rangeOfMarker(in data: Data, marker: Data, from start: Int) -> Range<Int>? {
        guard !marker.isEmpty, start < data.count else { return nil }
        // Naive byte search; sufficient for typical message sizes.
        let limit = data.count - marker.count
        if limit < start { return nil }
        var i = start
        while i <= limit {
            var matched = true
            for j in 0..<marker.count where data[i + j] != marker[j] {
                matched = false
                break
            }
            if matched {
                return i..<(i + marker.count)
            }
            i += 1
        }
        return nil
    }

    private func decode(body: Data, encoding: String) throws -> Data {
        switch encoding {
        case "base64":
            // Strip whitespace from body for base64 tolerance.
            let stripped = body.filter { $0 != 0x0A && $0 != 0x0D && $0 != 0x20 && $0 != 0x09 }
            guard let decoded = Data(base64Encoded: stripped, options: .ignoreUnknownCharacters)
            else {
                throw MailBladeError.decodeFailure(
                    messageID: messageID,
                    reason: "base64 decode failed"
                )
            }
            return decoded
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        case "7bit", "8bit", "binary", "":
            return body
        default:
            // Unknown encoding — return raw and hope.
            return body
        }
    }

    private func decodeQuotedPrintable(_ data: Data) -> Data {
        var out = Data()
        var i = 0
        while i < data.count {
            let b = data[i]
            if b == 0x3D {  // '='
                // Soft line break: =CRLF or =LF
                if i + 1 < data.count, data[i + 1] == 0x0A {
                    i += 2
                    continue
                }
                if i + 2 < data.count, data[i + 1] == 0x0D, data[i + 2] == 0x0A {
                    i += 3
                    continue
                }
                if i + 2 < data.count {
                    let hi = hexValue(data[i + 1])
                    let lo = hexValue(data[i + 2])
                    if let h = hi, let l = lo {
                        out.append(UInt8(h << 4 | l))
                        i += 3
                        continue
                    }
                }
                // Malformed — pass through.
                out.append(b)
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    private func hexValue(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)
        case 0x41...0x46: return Int(b - 0x41 + 10)
        case 0x61...0x66: return Int(b - 0x61 + 10)
        default: return nil
        }
    }

    private func textFromBytes(_ data: Data, charset: String?) -> String {
        let preferred = (charset ?? "utf-8").lowercased()
        let encoding: String.Encoding = {
            switch preferred {
            case "utf-8", "utf8": return .utf8
            case "us-ascii", "ascii": return .ascii
            case "iso-8859-1", "latin1", "iso-latin-1": return .isoLatin1
            case "iso-8859-2": return .isoLatin2
            case "windows-1252", "cp1252": return .windowsCP1252
            case "utf-16": return .utf16
            default: return .utf8
            }
        }()
        if let s = String(data: data, encoding: encoding) { return s }
        // Fallback chain: utf-8 → latin-1.
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private func stripAngleBrackets(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("<") { t = String(t.dropFirst()) }
        if t.hasSuffix(">") { t = String(t.dropLast()) }
        return t
    }
}

// MARK: - EMLXParser internal helper exposed for MIMEWalker re-parsing parts

extension EMLXParser {
    /// Same logic as `parseHeaders` but exposed for re-parsing nested
    /// multipart parts. Internal-only; consumers go through `parse(_:)`.
    func parseHeadersInternal(
        _ data: Data, messageID: Int64
    )
        throws -> ([String: [String]], Int)
    {
        return try parseHeaders(data, messageID: messageID)
    }
}

// MARK: - RFC2047 encoded-word decoding

enum RFC2047 {
    /// Decode any `=?charset?Q?text?=` / `=?charset?B?text?=` tokens in `s`.
    /// Tokens that don't match the form pass through verbatim.
    static func decode(_ s: String) -> String {
        // Apple-tolerant regex: `=?<charset>?<encoding>?<text>?=` where text
        // continues until the closing `?=` (greedy on text but bounded by
        // the next `?=`). Standard says encoded words are separated by
        // whitespace; we tolerate adjacent encoded-words with no spacing.
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            // Find next `=?`.
            if let start = s.range(of: "=?", range: i..<s.endIndex) {
                // Append literal up to the encoded-word.
                result.append(contentsOf: s[i..<start.lowerBound])
                // Find closing `?=` after `=?`.
                if let end = s.range(of: "?=", range: start.upperBound..<s.endIndex) {
                    let token = String(s[start.upperBound..<end.lowerBound])
                    if let decoded = decodeOneToken(token) {
                        result.append(decoded)
                        i = end.upperBound
                        continue
                    }
                    // Failed to decode — pass the literal through.
                    result.append(contentsOf: s[start.lowerBound..<end.upperBound])
                    i = end.upperBound
                } else {
                    // No closing — pass remainder verbatim.
                    result.append(contentsOf: s[start.lowerBound..<s.endIndex])
                    i = s.endIndex
                }
            } else {
                result.append(contentsOf: s[i..<s.endIndex])
                i = s.endIndex
            }
        }
        return result
    }

    /// Decode the inside of an encoded-word: `<charset>?<encoding>?<text>`.
    private static func decodeOneToken(_ token: String) -> String? {
        let parts = token.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let charset = String(parts[0]).lowercased()
        let encoding = String(parts[1]).uppercased()
        let text = String(parts[2])

        let bytes: Data?
        switch encoding {
        case "Q":
            bytes = decodeQ(text)
        case "B":
            bytes = Data(base64Encoded: text, options: .ignoreUnknownCharacters)
        default:
            return nil
        }
        guard let data = bytes else { return nil }
        let stringEncoding: String.Encoding = {
            switch charset {
            case "utf-8", "utf8": return .utf8
            case "us-ascii", "ascii": return .ascii
            case "iso-8859-1", "latin1", "iso-latin-1": return .isoLatin1
            case "iso-8859-2": return .isoLatin2
            case "windows-1252", "cp1252": return .windowsCP1252
            default: return .utf8
            }
        }()
        return String(data: data, encoding: stringEncoding) ?? String(data: data, encoding: .utf8)
    }

    /// Decode RFC2047 Q-encoding (similar to quoted-printable but `_` → space).
    private static func decodeQ(_ s: String) -> Data {
        var out = Data()
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x5F {  // '_'
                out.append(0x20)
                i += 1
            } else if b == 0x3D, i + 2 < bytes.count {
                let hi = hexNibble(bytes[i + 1])
                let lo = hexNibble(bytes[i + 2])
                if let h = hi, let l = lo {
                    out.append(UInt8(h << 4 | l))
                    i += 3
                } else {
                    out.append(b)
                    i += 1
                }
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    private static func hexNibble(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)
        case 0x41...0x46: return Int(b - 0x41 + 10)
        case 0x61...0x66: return Int(b - 0x61 + 10)
        default: return nil
        }
    }
}
