import Foundation

/// Explicit, bounded browser requests that do not need a language-model rewrite.
/// The worker still validates the destination and opens only observed results.
enum BrowserFastPath {
    static func youtubeVideoRequest(_ request: String) -> Bool {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\n") else { return false }
        let pattern = #"^(?:please\s+)?(?:(?:open|create) (?:a )?new tab(?: in (?:google chrome|chrome|safari|firefox|microsoft edge|edge|brave|brave browser|arc))?\s*(?:,?\s*(?:and then|and|then)\s+)?)?(?:go to |open |visit |launch )?(?:the )?you\s*tube(?: (?:website|site))?\s*(?:,?\s*(?:and then|and|then)\s*)?(?:find(?: me)?|search(?: youtube)? for|look up|show me)\s+(.+?)\s*[.!?]?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range(at: 1).location != NSNotFound else { return false }
        let query = (text as NSString).substring(with: match.range(at: 1))
        guard query.range(of: #"\b(?:video|videos|clip|clips)\b"#, options: .regularExpression) != nil else { return false }
        return query.range(of: #"\b(?:then|afterwards|after that)\b|(?:\band\b|[;.!?])\s*(?:open|close|delete|send|book|buy|click|save|download|compare|summarize|tell|fill|sign|log|go|find|search)\b"#, options: [.regularExpression,.caseInsensitive]) == nil
    }
}
