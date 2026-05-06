import Foundation

/// Factory for synthetic `.emlx` files. Each helper returns the raw bytes
/// of an `.emlx` payload (length-prefix + RFC822 + plist trailer) that the
/// parser can consume. Tests use these to exercise the parser in isolation
/// or in fixture-backed integration tests when paired with
/// `SampleEnvelopeBuilder`.
enum SampleEMLXBuilder {

    /// Wrap raw RFC822 bytes in the `.emlx` length-prefix envelope. The
    /// trailing plist is omitted (Apple's parser ignores anything after
    /// the declared length, so we just include exactly N bytes).
    static func emlxFromRFC822(_ rfc822: String) -> Data {
        let payloadBytes = Array(rfc822.utf8)
        let lengthPrefix = "\(payloadBytes.count)\n"
        var data = Data()
        data.append(contentsOf: Array(lengthPrefix.utf8))
        data.append(contentsOf: payloadBytes)
        return data
    }

    /// Minimal text/plain message.
    static let textPlain: String = """
        From: alice@example.com
        To: piers@mm.st
        Subject: Project status update
        Date: Sat, 01 Jun 2024 09:00:00 +0000
        Message-ID: <msg1@example.com>
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: 7bit

        Hello — quick update on the Q2 milestones, we are ahead of schedule.
        """

    /// multipart/alternative with text/plain + text/html.
    static let multipartAlternative: String = """
        From: bob@example.com
        To: piers@mm.st
        Subject: Newsletter — May edition
        Date: Wed, 05 Jun 2024 12:00:00 +0000
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="boundary-alt-001"

        --boundary-alt-001
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: 7bit

        This month: 5 articles on Apple silicon performance.
        --boundary-alt-001
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: 7bit

        <html><body><p>This month: <strong>5 articles</strong> on Apple silicon.</p></body></html>
        --boundary-alt-001--
        """

    /// multipart/mixed with a text part and an attachment.
    static let multipartMixedWithAttachment: String = """
        From: alice@example.com
        To: piers@mm.st
        Subject: Vacation photos
        Date: Mon, 06 May 2024 14:00:00 +0000
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="boundary-mix-001"

        --boundary-mix-001
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: 7bit

        Photos from Tasmania — see attachment.
        --boundary-mix-001
        Content-Type: image/jpeg; name="cradle-mountain.jpg"
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment; filename="cradle-mountain.jpg"

        SGVsbG8gd29ybGQgLSB0aGlzIGlzIG5vdCByZWFsbHkgYSBKUEVH
        --boundary-mix-001--
        """

    /// quoted-printable encoded body with non-ASCII characters.
    static let quotedPrintable: String = """
        From: piers@mm.st
        To: alice@example.com
        Subject: Re: Caf=C3=A9 visit
        Date: Tue, 07 May 2024 09:00:00 +0000
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Sounds great =E2=80=94 see you at the caf=C3=A9 at 10am.
        """

    /// RFC2047 encoded-word in subject + from.
    static let rfc2047EncodedHeaders: String = """
        From: =?utf-8?Q?Br=C3=A4dly?= <bradly@example.com>
        To: piers@mm.st
        Subject: =?utf-8?B?VGVzdCDigJQgRW1vamkg8J+Yig==?=
        Date: Wed, 08 May 2024 09:00:00 +0000
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: 7bit

        Encoded headers, plain body.
        """

    /// base64-encoded text body.
    static let base64Body: String = """
        From: alice@example.com
        To: piers@mm.st
        Subject: Lunch this week?
        Date: Sun, 02 Jun 2024 15:00:00 +0000
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        VGh1cnNkYXkgb3IgRnJpZGF5IHdvcmsgZm9yIGx1bmNoPyBNeSBzY2hlZHVsZSBvcGVucyB1cCBh
        ZnRlciAxcG0u
        """

    /// Reply with In-Reply-To header.
    static let replyMessage: String = """
        From: piers@mm.st
        To: alice@example.com
        Subject: Re: Project status update
        Date: Sun, 02 Jun 2024 09:00:00 +0000
        Message-ID: <msg2@example.com>
        In-Reply-To: <msg1@example.com>
        References: <msg1@example.com>
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: 7bit

        Reply with revised dates for the launch.
        """

    /// Write an `.emlx` file at the given on-disk path. Returns the path.
    static func writeEMLX(_ rfc822: String, atPath path: String) throws -> String {
        let data = emlxFromRFC822(rfc822)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Write an attachment file under the standard `Attachments/<msgID>/<part>/<filename>`
    /// structure. `mboxRoot` should point at the mailbox root (parent of
    /// both `Data/` and `Attachments/`).
    static func writeAttachment(
        bytes: Data, filename: String, messageID: Int64, partIndex: Int,
        mboxRoot: String
    ) throws -> String {
        let dir = "\(mboxRoot)/Attachments/\(messageID)/\(partIndex)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let path = "\(dir)/\(filename)"
        try bytes.write(to: URL(fileURLWithPath: path))
        return path
    }
}
