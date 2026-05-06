// SmokeTest.swift
//
// Phase A.0 placeholder, retained at A.1 as a fast-path sanity check that
// the test target builds and the library namespace is reachable. Real
// fixture-backed coverage lives in MailStoreReadTests + ConfigTests.

import XCTest

@testable import AppleMailBlade

final class SmokeTest: XCTestCase {

    func testLibraryNamespaceCompiles() {
        let _: AppleMailBlade.Type = AppleMailBlade.self
    }

    func testSemverIsNonEmpty() {
        XCTAssertFalse(AppleMailBlade.semver.isEmpty, "semver string must not be empty")
    }

    func testRegistryConstructionFailsCleanlyWithoutRealStore() async {
        // Default config points at the real ~/Library/Mail/V10/Envelope Index.
        // CI runners + sandboxed test bots have no Mail.app data — registry
        // construction should fail with storeMissing or permissionDenied,
        // never crash. This guards the lazy-init pattern that
        // AppleMailBladeWiring.SharedRegistry will rely on at Phase A.5.
        do {
            _ = try AppleMailToolRegistry()
            // Construction succeeded — there must be a real store on disk.
            // Acceptable: this machine has Mail data and the test runner has FDA.
        } catch let error as MailBladeError {
            switch error {
            case .storeMissing, .permissionDenied:
                break  // Expected on machines without Mail / FDA
            default:
                XCTFail("unexpected MailBladeError: \(error.loggableDescription)")
            }
        } catch {
            XCTFail("unexpected non-MailBladeError: \(error)")
        }
    }
}
