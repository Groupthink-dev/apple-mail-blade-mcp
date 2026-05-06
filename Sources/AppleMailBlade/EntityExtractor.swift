import Foundation
import NaturalLanguage

/// Deterministic feature extraction over message body text per DD-240
/// invariant #3 carve-out.
///
/// Three signals returned per message:
/// - **Language** — ISO 639-1 code via `NLLanguageRecognizer`. Returns
///   `"und"` (undetermined) for empty / very-short / mixed-script bodies.
/// - **Named entities** — people / organisations / places via `NLTagger`'s
///   `.nameType` scheme. Apple ships per-language models; we surface
///   whatever the framework returns.
/// - **Dates** — extracted by `NSDataDetector` with `.date` checking type.
///   Returned as ISO-8601 strings for stable JSON serialisation.
///
/// All three are framework-deterministic — no model choice, no probabilistic
/// inference outside the data-detection layer. Errors carry the message ID
/// for correlation but never the body content.
public struct EntityExtractor: Sendable {

    public init() {}

    /// Extract entities from a message body. Empty body → language "und"
    /// + empty arrays. Calls are not cached at this layer.
    public func extract(messageID: Int64, bodyText: String) -> Entities {
        guard !bodyText.isEmpty else {
            return Entities(
                messageID: messageID,
                language: "und",
                people: [],
                orgs: [],
                places: [],
                dates: []
            )
        }

        let language = detectLanguage(in: bodyText)
        let (people, orgs, places) = extractNamedEntities(
            in: bodyText, language: language
        )
        let dates = extractDates(in: bodyText)
        return Entities(
            messageID: messageID,
            language: language,
            people: people,
            orgs: orgs,
            places: places,
            dates: dates
        )
    }

    // MARK: - Language detection

    private func detectLanguage(in text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else { return "und" }
        return dominant.rawValue
    }

    // MARK: - Named entities

    private func extractNamedEntities(
        in text: String, language: String
    ) -> (
        people: [String], orgs: [String], places: [String]
    ) {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let nlLang = NLLanguage(rawValue: language)
        if nlLang != .undetermined {
            tagger.setLanguage(nlLang, range: text.startIndex..<text.endIndex)
        }

        var people = OrderedSet<String>()
        var orgs = OrderedSet<String>()
        var places = OrderedSet<String>()

        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            guard let tag = tag else { return true }
            let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return true }
            switch tag {
            case .personalName:
                people.insert(token)
            case .organizationName:
                orgs.insert(token)
            case .placeName:
                places.insert(token)
            default:
                break
            }
            return true
        }
        return (people.values, orgs.values, places.values)
    }

    // MARK: - Dates

    private func extractDates(in text: String) -> [String] {
        guard
            let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.date.rawValue
            )
        else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var seen = Set<String>()
        var dates: [String] = []
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let m = match, let d = m.date else { return }
            let iso = formatter.string(from: d)
            if !seen.contains(iso) {
                seen.insert(iso)
                dates.append(iso)
            }
        }
        return dates
    }
}

// MARK: - OrderedSet helper

/// Insertion-ordered, deduplicating collection. Used so entity lists keep
/// the order they appear in the source text rather than alphabetising.
private struct OrderedSet<Element: Hashable> {
    private var seen = Set<Element>()
    private var ordered: [Element] = []

    mutating func insert(_ element: Element) {
        if seen.insert(element).inserted {
            ordered.append(element)
        }
    }

    var values: [Element] { ordered }
}
