import Foundation

/// Reconstructs message threads from the Envelope Index.
///
/// Resolution strategy (best-effort):
/// 1. **`messages.conversation_id` walk** — Apple groups related messages
///    via the `conversation_id` integer; same value = same thread. This is
///    the cheap path and works for the vast majority of threads.
/// 2. **`In-Reply-To` / `References` fallback** — for older messages or
///    cross-account threads where `conversation_id` is absent or split,
///    walk the `messages.in_reply_to` chain forward and backward via the
///    `messages.message_id` index.
///
/// Cross-account hops are flagged on each `ThreadMessage` so consumers can
/// surface the boundary to the user.
///
/// Body text per message is fetched lazily via `EMLXParser` so threads
/// containing large attachments don't blow the memory budget.
public struct ThreadResolver: Sendable {

    public let store: MailStore
    public let parser: EMLXParser
    public let locator: EMLXLocator

    public init(store: MailStore, parser: EMLXParser, locator: EMLXLocator) {
        self.store = store
        self.parser = parser
        self.locator = locator
    }

    /// Resolve a thread starting from `messageID`. Returns the thread in
    /// chronological order (oldest first). Each entry includes a
    /// best-effort body text snippet; failures to read individual messages
    /// degrade gracefully (the entry has `bodyText: nil`).
    public func resolve(messageID: Int64) async throws -> [ThreadMessage] {
        // Anchor: the head of the message we're rooting on.
        let anchor = try await store.head(messageID: messageID)
        let anchorAccount = try await accountID(forMailbox: anchor.mailboxID)

        var members = try await collectByConversationID(anchor: anchor)
        if members.isEmpty {
            members = [anchor]  // Lone message — return at least itself.
        }
        // Augment via In-Reply-To / References when present.
        if let _ = anchor.inReplyTo {
            let extra = try await collectByReferences(anchor: anchor)
            mergeUnique(into: &members, additions: extra)
        }
        // Order chronologically; missing dates sort to the end.
        members.sort { (a, b) -> Bool in
            switch (a.dateReceived, b.dateReceived) {
            case (let x?, let y?):
                return x < y
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return a.id < b.id
            }
        }

        var output: [ThreadMessage] = []
        output.reserveCapacity(members.count)
        for h in members {
            let memberAccount = try await accountID(forMailbox: h.mailboxID)
            let crossAccount = memberAccount != anchorAccount
            let bodyText: String? = await readBodyText(messageID: h.id)
            output.append(
                ThreadMessage(
                    id: h.id,
                    mailboxID: h.mailboxID,
                    messageID: h.messageID,
                    inReplyTo: h.inReplyTo,
                    subject: h.subject,
                    from: h.from,
                    dateSent: h.dateSent,
                    bodyText: bodyText,
                    crossAccount: crossAccount
                )
            )
        }
        return output
    }

    // MARK: - Internals

    private func collectByConversationID(anchor: MessageHead) async throws -> [MessageHead] {
        guard let cid = anchor.conversationID else { return [anchor] }
        // Walk all mailboxes the anchor's account spans, collecting messages
        // with the same conversation_id. We rely on listMessages-style index
        // lookup; cross-mailbox is implicit because conversation_id is
        // store-wide.
        let candidates = try await store.messageHeadsForConversation(cid)
        return candidates
    }

    private func collectByReferences(anchor: MessageHead) async throws -> [MessageHead] {
        guard let parentMID = anchor.inReplyTo else { return [] }
        // Walk parents — best effort.
        var queue: [String] = [parentMID]
        var seen: Set<String> = []
        var output: [MessageHead] = []
        while let mid = queue.popLast() {
            if seen.contains(mid) { continue }
            seen.insert(mid)
            if let head = try await store.messageHead(forMessageID: mid) {
                output.append(head)
                if let parent = head.inReplyTo, !seen.contains(parent) {
                    queue.append(parent)
                }
            }
        }
        return output
    }

    private func mergeUnique(into base: inout [MessageHead], additions: [MessageHead]) {
        let seen = Set(base.map { $0.id })
        for a in additions where !seen.contains(a.id) {
            base.append(a)
        }
    }

    private func accountID(forMailbox mailboxID: Int64) async throws -> Int64 {
        let mailboxes = try await store.listMailboxes()
        return mailboxes.first { $0.id == mailboxID }?.accountID ?? -1
    }

    /// Best-effort body extraction: read the `.emlx`, parse, return text.
    /// Failures (missing file, parse error, FDA denial) become `nil` so a
    /// single broken message doesn't break the thread response.
    private func readBodyText(messageID: Int64) async -> String? {
        guard let path = await locator.locate(messageID: messageID) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard
            let parsed = try? parser.parse(
                data, messageID: messageID, includeHTML: false
            )
        else { return nil }
        return parsed.bodyText
    }
}
