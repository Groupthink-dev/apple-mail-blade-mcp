import XCTest

@testable import AppleMailBlade

/// Unit tests for `EntityExtractor`. NaturalLanguage models are
/// version-dependent — assertions check for *plausible* output rather
/// than exact-match (e.g. "people contains some name token") to remain
/// stable across macOS releases.
final class EntityExtractorTests: XCTestCase {

    let extractor = EntityExtractor()

    // MARK: - Language detection

    func testEmptyBodyReturnsUndetermined() {
        let result = extractor.extract(messageID: 1, bodyText: "")
        XCTAssertEqual(result.language, "und")
        XCTAssertTrue(result.people.isEmpty)
        XCTAssertTrue(result.orgs.isEmpty)
        XCTAssertTrue(result.places.isEmpty)
        XCTAssertTrue(result.dates.isEmpty)
    }

    func testEnglishBodyDetectedAsEnglish() {
        let result = extractor.extract(
            messageID: 2,
            bodyText:
                "I had lunch with Sarah Johnson yesterday at the new "
                + "Italian restaurant in Sydney. Her company, Acme Corp, "
                + "is hiring engineers."
        )
        XCTAssertEqual(result.language, "en")
    }

    func testFrenchBodyDetectedAsFrench() {
        let result = extractor.extract(
            messageID: 3,
            bodyText:
                "J'ai déjeuné avec Marie Dupont hier au nouveau restaurant "
                + "italien à Paris. Son entreprise, Acme Corp, recrute des ingénieurs."
        )
        XCTAssertEqual(result.language, "fr")
    }

    // MARK: - Named entities

    func testPeopleAreExtracted() {
        let result = extractor.extract(
            messageID: 4,
            bodyText:
                "Please confirm with Sarah Johnson and Bob Williams "
                + "before Friday's meeting."
        )
        XCTAssertFalse(result.people.isEmpty, "expected NLTagger to find people")
        // At least one of the names should be present (NLTagger may segment
        // first/last differently across macOS versions; just check for substring).
        let joined = result.people.joined(separator: " ")
        XCTAssertTrue(
            joined.contains("Sarah") || joined.contains("Bob")
                || joined.contains("Williams") || joined.contains("Johnson"),
            "no recognisable name in: \(result.people)"
        )
    }

    func testPlacesAreExtracted() {
        let result = extractor.extract(
            messageID: 5,
            bodyText:
                "We are flying from Sydney to London via Singapore next week. "
                + "The Tasmania trip was great."
        )
        XCTAssertFalse(result.places.isEmpty, "expected NLTagger to find places")
        let joined = result.places.joined(separator: " ")
        XCTAssertTrue(
            joined.contains("Sydney") || joined.contains("London")
                || joined.contains("Singapore") || joined.contains("Tasmania"),
            "no recognisable place in: \(result.places)"
        )
    }

    // MARK: - Date extraction (NSDataDetector)

    func testDatesAreExtractedFromBody() {
        let result = extractor.extract(
            messageID: 6,
            bodyText:
                "Let's meet on March 15, 2025 at 3pm. The deadline is April 1, 2025."
        )
        XCTAssertFalse(result.dates.isEmpty, "expected NSDataDetector to find dates")
        // ISO-8601 strings — should at minimum contain a year-month-day match.
        XCTAssertTrue(
            result.dates.contains { $0.contains("2025-03-15") || $0.contains("2025-04-01") },
            "no recognisable date in: \(result.dates)"
        )
    }

    func testNoDatesInPlainBody() {
        let result = extractor.extract(
            messageID: 7,
            bodyText: "Just a quick hello with no temporal references."
        )
        XCTAssertTrue(result.dates.isEmpty, "unexpected dates: \(result.dates)")
    }

    // MARK: - Determinism

    func testRepeatedCallsProduceIdenticalOutput() {
        let body =
            "Sarah Johnson and Bob Williams met at Acme Corp's "
            + "Sydney office on March 15, 2025."
        let r1 = extractor.extract(messageID: 8, bodyText: body)
        let r2 = extractor.extract(messageID: 8, bodyText: body)
        XCTAssertEqual(r1.language, r2.language)
        XCTAssertEqual(r1.people, r2.people)
        XCTAssertEqual(r1.orgs, r2.orgs)
        XCTAssertEqual(r1.places, r2.places)
        XCTAssertEqual(r1.dates, r2.dates)
    }

    // MARK: - Insertion-ordered dedup

    func testDuplicateEntitiesAreDedupedPreservingFirstOccurrence() {
        let result = extractor.extract(
            messageID: 9,
            bodyText:
                "Sarah called. Then Bob called. Then Sarah called again. "
                + "Then Sarah and Bob both came in."
        )
        // No duplicates: every entry in result.people is unique.
        XCTAssertEqual(Set(result.people).count, result.people.count)
    }
}
