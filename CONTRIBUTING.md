# Contributing

This is a Stallari-internal repo. Contribution patterns assume you're a future
me, an architect session, or an authorised collaborator working on the
Stallari platform — not an external open-source contributor.

## Coding standards

- **Format with `swift-format`.** `make format-check` must pass before commit.
  The repo's `.swift-format` is the source of truth.
- **No external dependencies beyond what `Package.swift` declares.** Today
  that's `MCP` (via local-path `swift-sdk`) and `SQLite.swift` (with the
  SQLCipher trait, for SPM-graph compatibility with the harness — the trait
  is not used at runtime).
- **No probabilistic inference.** This is a class invariant from
  [DD-240](../master-ai/atlas/utilities/agent-harness/decisions/DD-240.md)
  invariant #3. PRs that add LLM calls or user-loaded CoreML get rejected.
  NLTagger entity extraction is allowed under the deterministic-extraction
  carve-out.
- **No network egress.** The library doesn't link a network framework. PRs
  that change this need to come with a DD justifying the change.
- **Errors carry IDs only, never bodies/subjects/sender addresses.** This is
  privacy hygiene — errors propagate through Stallari traces and external logs.
- **Bounded parsers.** All `.emlx` parsing has explicit max-recursion and
  max-size caps; any new recursion path or unbounded loop needs a cap before
  PR is mergeable.

## Tests

- **Fixtures only in CI.** `Tests/AppleMailBladeTests/Fixtures/` builds
  synthetic Envelope Index + `.emlx` blobs under `/private/tmp/` — never the
  user's real Mail.app data.
- **Never commit real Mail data.** The `.gitignore` has explicit guards
  (`*.sqlite`, `Envelope*Index*`, `*.emlx`, `*.mbox/`, `MailData/`,
  `fixtures/real/`); double-check before adding test fixtures.
- **Add a regression test for every bug fix.** `.emlx` format edge cases
  especially — Apple ships variants in obscure cases (multipart/alternative
  with broken boundary, RFC2047 encoded-word in odd positions, top-posted
  replies that strip `References`).

## Local Stallari testing

To test changes against the real Stallari harness without tagging the blade:

1. Confirm `~/src/apple-mail-blade-mcp/` and `~/src/stallari-harness/` are
   sibling directories on disk.
2. Add `.package(path: "../apple-mail-blade-mcp")` to harness `Package.swift`
   if not already present (lands at Phase A.5 per implementation plan).
3. From `~/src/stallari-harness/` run `make install-dev`. Stallari rebuilds
   with your local changes compiled in.
4. Tests: `swift test --filter AppleMailBladeWiringTests` runs the harness-
   side tests. They include the regression guard
   `testMailNotAdvertisedExternally` — keep that test green.

## No online CI signing

We don't sign anything in this repo's CI. No Apple developer credentials in
GitHub Secrets. No notarised pkg release. The signing event happens locally
in `stallari-harness/Makefile`'s `make dist`, which signs the entire `.app`
including this library compiled into StallariKit.

If a future need surfaces for an external surface (e.g. a Mail triage CLI
that ships standalone), that change comes via a separate DD that revisits
the distribution model — it is not a casual addition.

## Versioning

SemVer. Pre-release suffixes (`v0.1.0-rc1`) are allowed and indicate the
library is feature-complete locally but hasn't been wired into a Stallari
release yet. Consumers should pin by commit SHA while the suffix is
non-empty. `Sources/AppleMailBlade/Version.swift` is the canonical
SemVer string; bump it together with the git tag.

## License

MIT — see [LICENSE](./LICENSE). All contributions are accepted under the same.
