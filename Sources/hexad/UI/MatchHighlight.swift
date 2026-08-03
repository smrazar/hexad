import SwiftUI

/// A title with the letters the search matched picked out.
///
/// One builder rather than three, because Square, List and Grid all show titles and all three
/// filter through the same scorer — three hand-rolled highlighters would drift, and a highlight
/// that disagrees with the ranking is worse than none.
enum MatchHighlight {

    /// The title as an `AttributedString`, matched characters in the accent and a heavier weight.
    ///
    /// Weight as well as colour, because §12 does not let colour carry meaning on its own — and
    /// on a preview tile the accent alone can land on an amber pixel and vanish.
    static func title(_ text: String,
                      query: String,
                      base: NSColor,
                      accent: NSColor = Palette.NS.accent) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = Color(nsColor: base)

        // Match against the same string the filter ranks on — app name, then title — but only
        // mark the part of it the user is actually looking at.
        let indices = Set(FuzzyMatch.matchedIndices(query, against: text))
        guard !indices.isEmpty else { return attributed }

        for (offset, character) in text.enumerated() where indices.contains(offset) {
            guard let range = rangeOf(character: offset, in: attributed, source: text) else {
                continue
            }
            attributed[range].foregroundColor = Color(nsColor: accent)
            attributed[range].font = Font(Theme.Font.bodyEmph)
            _ = character
        }
        return attributed
    }

    /// `AttributedString` indices are not integers, so a character offset has to be walked to.
    /// Cheap here: titles are short and this runs once per visible row, never per frame.
    private static func rangeOf(character offset: Int,
                                in attributed: AttributedString,
                                source: String) -> Range<AttributedString.Index>? {
        guard offset < source.count else { return nil }
        let start = attributed.index(attributed.startIndex, offsetByCharacters: offset)
        let end = attributed.index(start, offsetByCharacters: 1)
        return start..<end
    }
}
