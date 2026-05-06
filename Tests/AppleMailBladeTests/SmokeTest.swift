// SmokeTest.swift
//
// Phase A.0 placeholder: confirms the test target builds and runs at all.
// Replaced/extended in subsequent phases with real fixture-backed tests.

import XCTest
@testable import AppleMailBlade

final class SmokeTest: XCTestCase {

    func testLibraryNamespaceCompiles() {
        // If this compiles and runs, the SPM target wiring is sound.
        let _: AppleMailBlade.Type = AppleMailBlade.self
    }

    func testSemverIsNonEmpty() {
        XCTAssertFalse(AppleMailBlade.semver.isEmpty, "semver string must not be empty")
    }
}
