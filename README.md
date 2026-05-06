# apple-mail-blade-mcp

Stallari-internal Swift library blade for read-only access to Apple Mail (`~/Library/Mail/V10/MailData/Envelope Index` SQLite + `.emlx` message bodies + `Attachments/` subtree). Consumed by `StallariKit` via SPM dependency; never exposed externally.

**Audience:** future me + future architect sessions debugging an Envelope Index or `.emlx` parser regression. This is **not** a third-party MCP server. There is no notarised installer, no Claude Desktop snippet, no PyPI/Homebrew distribution.

> **Status:** Phase A.0 scaffold (2026-05-06). Real surface lands across A.1–A.5 per `[[DD-241-implementation-plan]]`. Full README rewritten at A.5.

---

## Class context

Second concrete blade under the local-corpus class defined in [DD-240](../master-ai/atlas/utilities/agent-harness/decisions/DD-240.md). Sibling: `apple-notes-blade-mcp` (DD-240 Phase A, shipped 2026-05-06). Existing kin: `apple-reminders-blade-mcp` (Python — EventKit-via-pyobjc carve-out per DD-240 invariant #6).

The class invariants this blade conforms to live at `directives/local-corpus-blades.md`. The most load-bearing ones for this repo:

- **No probabilistic inference.** NLTagger entity extraction (Phase A.3) is deterministic, framework-only.
- **Read-only.** SQLite opened with `SQLITE_OPEN_READONLY`. `.emlx` files are immutable post-write by Mail.app.
- **No network.** The library doesn't link a network framework.
- **Hardcoded read paths.** `Config.storePath` validates against the canonical `~/Library/Mail/V10/` prefix.
- **Bounded parser.** Hand-rolled `.emlx` parser with max 32 nested multipart levels, max 100MB message size, max 25MB attachment.

## Why a separate repo

Clean module boundary, mirrors the `apple-notes-blade-mcp` shape (also Swift, also raw-disk reads), shippable independently if external exposure is ever wanted later.

## No external exposure

The 8 Mail tools (final surface, lands across A.1–A.4) are wired into the Stallari daemon's *internal* tool routing only. They never appear on the public `:9847/mcp` HTTP MCP surface. Enforcement:

- `AppleMailBladeWiring` in `stallari-harness/Sources/StallariKit/Blades/` exposes the registry via an internal accessor (Phase A.5).
- `DaemonMCPServer`'s composite router is **not** wired up to consult this registry.
- `AppleMailBladeWiringTests.testMailNotAdvertisedExternally` verifies that no `apple_mail_*` tool is registered with the public `ToolCatalog`. This test is a load-bearing regression guard — do not weaken or skip it.

If an external MCP client (Claude Desktop, third-party) connects to `:9847/mcp` and runs `tools/list`, no Mail tools are returned. Mesh transport inherits the same filter, so per-device Mail data does not cross the user's own fleet either.

## Tools (final surface, lands A.1–A.3)

Eight tools, all read-only:

| Tool | Purpose | Lands |
|---|---|---|
| `apple_mail_list_accounts` | Enumerate accounts. | A.1 |
| `apple_mail_list_mailboxes` | Mailbox tree, optional account filter. | A.1 |
| `apple_mail_list_messages` | List messages in a mailbox. Index-only — never opens `.emlx`. | A.1 |
| `apple_mail_search_messages` | LIKE-based substring search over subjects + summaries. | A.1 |
| `apple_mail_head` | Cheap metadata lookup; never opens `.emlx`. | A.1 |
| `apple_mail_read_message` | Open `.emlx`, return parsed body + attachments meta. | A.2 |
| `apple_mail_read_attachment` | Read a single attachment from the `Attachments/` subtree. 25MB cap. | A.2 |
| `apple_mail_read_thread` | Reconstruct a thread via `conversation_id` + `In-Reply-To`/`References`. | A.2 |
| `apple_mail_extract_entities` | NLTagger entity / language / token extraction. | A.3 |

## Schema notes (filled in A.1–A.2)

### Envelope Index (V10, macOS 14+)

Apple's `Envelope Index` is a SQLite database under `~/Library/Mail/V10/MailData/`. Tables of interest: `messages`, `addresses`, `subjects`, `mailboxes`, `recipients`, `summaries`, `accounts`. v0.1.0 supports V10 only; older schema versions (V9, V8) are deferred until a real user demands them.

### `.emlx` format (hand-rolled parser, A.2)

Each message body is a `.emlx` file: a leading length-prefix (decimal, newline-terminated) + RFC822 payload + property-list trailer. The hand-rolled parser handles encoded-word headers, multipart MIME, base64/quoted-printable encodings, with bounded recursion (max 32 levels) + max-size guards (100MB message, 25MB attachment).

## Updating

```sh
make test                  # fixture-only tests (never against real Mail.app data)
git tag -a v0.1.x -m "..."
git push origin v0.1.x

# In stallari-harness:
# Update the SPM ref (path or URL). Pin by SHA before the next Stallari tag.
```

## Troubleshooting

### `permission_denied`
The consuming binary (Stallari) does not have Full Disk Access. Open System Settings → Privacy & Security → Full Disk Access and enable Stallari. The error response always carries the System Settings pointer.

### `store_missing`
`Envelope Index` does not exist at the configured path. Either Mail.app has never been launched on this Mac, or Apple has shipped a new path schema. Check `~/Library/Mail/V10/MailData/`.

### `store_locked`
SQLite returned `SQLITE_BUSY` past the 200ms busy-timeout. Mail.app is in the middle of a write. Retry with backoff. Persistent lockups (>30s) are unusual and worth investigating.

### `decode_failure`
The `.emlx` parser hit one of its hard caps (max recursion, max size) or the length prefix was malformed. Carries the message ID for correlation but never the body.

### `attachment_too_large`
The requested attachment exceeds the 25MB cap. v0.2.0 may add chunked reads if a real consumer needs >25MB attachments.

### `invalid_store_path`
`Config.storePath` was set to a path outside the allowed prefixes (the canonical `~/Library/Mail/V10/` or `/private/tmp/`). This is intentional — only fixture tests should override the path.

## Development

```sh
make build           # swift build (debug)
make test            # swift test --enable-code-coverage
make lint            # swift-format lint
make format          # swift-format auto-format
make clean           # remove .build / .swiftpm
```

CI runs lint + build + test on macOS 14 and macOS 15. **No signing in CI**, no Apple developer credentials, no notarisation. The signing event happens locally in `stallari-harness/Makefile`'s `make dist`, which signs the entire `.app` (including this library compiled into StallariKit).

## HTML body sanitisation (privacy gotcha)

`apple_mail_read_message(include_html: true)` returns raw HTML. Tracking pixels, web bugs, and external resources are *not* stripped. Forwarding raw HTML to a cloud LLM leaks read-receipts to senders and other tracking. v0.1.0 punts sanitisation to the consumer; a future `sanitised_text` companion field may be added in v0.2.0 if a real consumer needs it.

## Security

See [SECURITY.md](./SECURITY.md). Report internal Stallari security issues via the Stallari security channel. Out of scope: any vulnerability requiring a non-Stallari MCP client to be wired up to this library — by design, that path doesn't exist.

## License

MIT — see [LICENSE](./LICENSE).
