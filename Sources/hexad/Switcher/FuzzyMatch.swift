import Foundation

/// Subsequence matching with a score, for the palette.
///
/// The bar is not "finds the window" — any substring search does that. It is that typing three
/// letters puts the window you meant **first**, which is a ranking problem rather than a filtering
/// one. So a match returns a score, and the score rewards the two things that separate the window
/// someone meant from one that merely contains the letters: matches at the **start of a word**, and
/// matches that run **consecutively**.
///
/// ponytail: this is a scored subsequence, not Smith-Waterman. It is a few dozen lines against a
/// list of tens of windows; a real sequence aligner is worth it when the corpus is thousands.
enum FuzzyMatch {

    private enum Score {
        static let base = 1
        /// Consecutive characters mean the user is typing a run, not scattering letters.
        static let consecutive = 8
        /// A match at a word start is almost always the intent — "sa" for "Safari".
        static let wordStart = 12
        /// The very first character of the candidate, stronger still.
        static let prefix = 16
        /// Every unmatched character makes the candidate a slightly worse fit.
        static let gapPenalty = -1
    }

    /// `nil` when `query` is not a subsequence of `candidate`. Case-insensitive.
    ///
    /// An empty query matches everything with score 0, so an unfiltered palette keeps the store's
    /// most-recently-used order rather than resorting itself into something arbitrary.
    static func score(_ query: String, against candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }

        let needle = Array(query.lowercased())
        let hay = Array(candidate.lowercased())
        let hayOriginal = Array(candidate)
        guard needle.count <= hay.count else { return nil }

        var total = 0
        var needleIndex = 0
        var lastMatch: Int?

        for (index, character) in hay.enumerated() {
            guard needleIndex < needle.count, character == needle[needleIndex] else { continue }

            var points = Score.base
            if index == 0 {
                points += Score.prefix
            } else if isWordBoundary(hay, hayOriginal, index) {
                points += Score.wordStart
            }
            if let lastMatch, lastMatch == index - 1 {
                points += Score.consecutive
            }
            total += points
            lastMatch = index
            needleIndex += 1
        }

        guard needleIndex == needle.count else { return nil }
        // Shorter candidates win ties: "Mail" should beat "Mailbox Settings" for "mail".
        return total + (hay.count - needle.count) * Score.gapPenalty
    }

    /// A word start is after a separator, or a capital in the middle of camelCase — which is how
    /// window titles like "iPhone Mirroring" and file names like "AppDelegate.swift" read.
    private static func isWordBoundary(_ lowered: [Character],
                                       _ original: [Character],
                                       _ index: Int) -> Bool {
        let previous = lowered[index - 1]
        if previous == " " || previous == "-" || previous == "_" || previous == "."
            || previous == "/" || previous == "—" {
            return true
        }
        return original[index].isUppercase && !original[index - 1].isUppercase
    }

    /// Which characters of `candidate` the query matched, so the UI can show *why* a result is in
    /// the list and in that position.
    ///
    /// The ranking is fuzzy, which means the order is not obvious from looking at it — "sfr"
    /// putting Safari above System Settings reads as arbitrary until the s, f and r are marked.
    /// Uses the same greedy left-to-right scan as `score`, so what is highlighted is exactly what
    /// was counted rather than a second opinion about the same string.
    static func matchedIndices(_ query: String, against candidate: String) -> [Int] {
        guard !query.isEmpty else { return [] }

        let needle = Array(query.lowercased())
        let hay = Array(candidate.lowercased())
        var indices: [Int] = []
        var needleIndex = 0

        for (index, character) in hay.enumerated() {
            guard needleIndex < needle.count, character == needle[needleIndex] else { continue }
            indices.append(index)
            needleIndex += 1
        }
        // A partial run is not a match, and highlighting one would mark letters in a row the
        // filter is about to drop.
        return needleIndex == needle.count ? indices : []
    }

    /// Ranks items, dropping non-matches. Ties keep the caller's original order, so an empty
    /// query leaves most-recently-used intact.
    static func rank<Item>(_ items: [Item],
                           query: String,
                           text: (Item) -> String) -> [Item] {
        guard !query.isEmpty else { return items }
        return items.enumerated()
            .compactMap { offset, item -> (Int, Int, Item)? in
                guard let score = score(query, against: text(item)) else { return nil }
                return (score, offset, item)
            }
            .sorted { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 > rhs.0
            }
            .map(\.2)
    }
}
