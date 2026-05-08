import Foundation
import MCP

/// Public registry façade. Mirrors the shape used by `apple-notes-blade-mcp`'s
/// `AppleNotesToolRegistry`: `tools()` returns the MCP tool definitions;
/// `handleCall` dispatches a CallTool by name to the appropriate handler.
///
/// **Internal-only consumption.** This registry is registered with
/// StallariKit's internal tool catalog only. The Mail tools are never
/// advertised on the daemon's public `:9847/mcp` HTTP MCP surface. See
/// `directives/local-corpus-blades.md` for the class invariants
/// (DD-240 #8) and the regression guard `testMailNotAdvertisedExternally`
/// in `stallari-harness/Tests/StallariKitTests/Blades/AppleMailBladeWiringTests.swift`
/// (lands at Phase A.5).
///
/// **Phasing.** Phase A.1 wires 5 fully-functional handlers (`list_accounts`,
/// `list_mailboxes`, `list_messages`, `search_messages`, `head`). Phase A.2
/// adds `read_message`, `read_attachment`, `read_thread`. Phase A.3 adds
/// `extract_entities`. Tools whose handlers haven't landed yet route to a
/// `not_implemented` error response so the surface stays stable.
public actor AppleMailToolRegistry {

    public let store: MailStore
    public let parser: EMLXParser
    public let locator: EMLXLocator
    public let attachmentReader: AttachmentReader
    public let threadResolver: ThreadResolver
    public let entityExtractor: EntityExtractor

    private let listAccounts: ListAccountsHandler
    private let listMailboxes: ListMailboxesHandler
    private let listMessages: ListMessagesHandler
    private let searchMessages: SearchMessagesHandler
    private let head: HeadHandler
    private let readMessage: ReadMessageHandler
    private let readAttachment: ReadAttachmentHandler
    private let readThread: ReadThreadHandler
    private let extractEntities: ExtractEntitiesHandler
    private let indexStatus: IndexStatusHandler
    private let reindex: ReindexHandler

    public init(
        config: MailBladeConfig,
        fts5Client: (any MailFTS5QueryClient)? = nil
    ) async throws {
        self.store = try MailStore(config: config)
        self.parser = EMLXParser(config: config)
        self.locator = EMLXLocator(config: config)
        self.attachmentReader = AttachmentReader(config: config, locator: locator)
        self.threadResolver = ThreadResolver(
            store: store, parser: parser, locator: locator
        )
        self.entityExtractor = EntityExtractor()

        self.listAccounts = ListAccountsHandler(store: store)
        self.listMailboxes = ListMailboxesHandler(store: store)
        self.listMessages = ListMessagesHandler(store: store)
        self.searchMessages = SearchMessagesHandler(store: store)
        self.head = HeadHandler(store: store)
        self.readMessage = ReadMessageHandler(
            store: store, parser: parser, locator: locator
        )
        self.readAttachment = ReadAttachmentHandler(
            store: store, reader: attachmentReader
        )
        self.readThread = ReadThreadHandler(resolver: threadResolver)
        self.extractEntities = ExtractEntitiesHandler(
            store: store, parser: parser, locator: locator, extractor: entityExtractor
        )
        // DD-256 §A.4: index introspection + reindex control surface.
        self.indexStatus = IndexStatusHandler(fts5Client: fts5Client)
        self.reindex = ReindexHandler()

        // Wire the FTS5 client into MailStore so `searchMessages` can
        // route between FTS5 and LIKE per `isHealthyForQuery`. Nil
        // client leaves MailStore on the LIKE path (existing v0.1.x
        // behaviour).
        if let fts5Client {
            await store.setFTS5QueryClient(fts5Client)
        }
    }

    /// Convenience constructor using the default canonical Mail.app path
    /// and no FTS5 client (LIKE path only).
    public init() async throws {
        try await self.init(config: try MailBladeConfig())
    }

    /// All tool definitions, suitable for ListTools response.
    public nonisolated func tools() -> [Tool] {
        MailToolSchemas.all()
    }

    /// Dispatch a CallTool. Unknown names return an internal-error result;
    /// not-yet-implemented tools (read_message etc. before A.2) return a
    /// `not_implemented` error.
    public func handleCall(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        switch name {
        case "apple_mail_list_accounts":
            return await listAccounts.handle(arguments: arguments)
        case "apple_mail_list_mailboxes":
            return await listMailboxes.handle(arguments: arguments)
        case "apple_mail_list_messages":
            return await listMessages.handle(arguments: arguments)
        case "apple_mail_search_messages":
            return await searchMessages.handle(arguments: arguments)
        case "apple_mail_head":
            return await head.handle(arguments: arguments)
        case "apple_mail_read_message":
            return await readMessage.handle(arguments: arguments)
        case "apple_mail_read_attachment":
            return await readAttachment.handle(arguments: arguments)
        case "apple_mail_read_thread":
            return await readThread.handle(arguments: arguments)
        case "apple_mail_extract_entities":
            return await extractEntities.handle(arguments: arguments)
        case "apple_mail_index_status":
            return await indexStatus.handle(arguments: arguments)
        case "apple_mail_reindex":
            return await reindex.handle(arguments: arguments)
        default:
            return errorResult(.internalError("unknown tool: \(name)"))
        }
    }

}
