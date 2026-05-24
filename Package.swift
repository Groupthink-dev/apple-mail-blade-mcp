// swift-tools-version: 6.1
import PackageDescription

// apple-mail-blade-mcp
//
// Stallari-internal Swift library blade for read-only access to Apple Mail
// (~/Library/Mail/V10/MailData/Envelope Index SQLite + .emlx message bodies +
// Attachments/ subtree). Defined by DD-241; second concrete blade in the
// local-corpus class (after apple-notes-blade-mcp; see DD-240).
//
// Consumed only via StallariKit's internal tool registry. Never exposed on the
// daemon's public :9847/mcp HTTP MCP surface. See README §"No external exposure".
//
// MCP dependency URL-pinned to piersdd/swift-sdk fork per DD-295 Phase C; promote
// to upstream when modelcontextprotocol/swift-sdk#NNN merges.

let package = Package(
    name: "apple-mail-blade-mcp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AppleMailBlade",
            targets: ["AppleMailBlade"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/piersdd/swift-sdk.git", from: "0.12.1"),
        // SQLite.swift with SQLCipher trait — matches stallari-harness'
        // SPM trait declaration so the merged graph resolves cleanly when
        // this library is embedded as an SPM dep. We don't *use* SQLCipher
        // (Apple's Envelope Index is plain SQLite); enabling the trait is
        // purely for resolution compatibility.
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3", traits: ["SQLCipher"]),
        // Canonical _meta: envelope helpers (DD-338 Phase E.swift). Replaces
        // the previously hand-rolled Sources/AppleMailBlade/MetaEnvelope.swift
        // (deleted in DD-338 Phase C Wave 5).
        .package(url: "https://github.com/Groupthink-dev/stallari-mcp-helpers-swift", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "AppleMailBlade",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "MCPHelpers", package: "stallari-mcp-helpers-swift"),
            ]
        ),
        .testTarget(
            name: "AppleMailBladeTests",
            dependencies: ["AppleMailBlade"]
        ),
    ]
)
