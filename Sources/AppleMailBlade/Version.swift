// Version.swift
//
// Canonical SemVer string for the apple-mail-blade-mcp library. Bump this
// together with the git tag. Pre-release suffixes (e.g. "0.1.0-rc1") are
// allowed and signal "feature-complete locally but not yet wired into a
// Stallari release."

extension AppleMailBlade {
    /// Library SemVer. Update this string at the same commit as the git tag.
    /// Pre-release suffix (`-rc1`) signals "feature-complete locally, awaiting
    /// real-corpus smoke + StallariKit wiring before v0.1.0 ships."
    public static let semver = "0.1.0-rc1"
}
