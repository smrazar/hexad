import CoreGraphics
import Foundation

/// How many columns the grid uses and how large a card is, so that **everything fits on screen**.
///
/// The grid is not a scrolling view and must never become one. The whole promise of "every window
/// at once" is that you can see them all and point at the one you want; a scroll bar breaks that
/// twice over — what is below the fold is invisible, and reaching it costs more than the ⌘Tab it
/// replaced.
///
/// **The first version of this solver still scrolled**, because it gave up too early in two ways:
/// it capped the content at 1180pt on a 1728pt display, throwing away a third of the width it
/// could have used for columns, and it refused to shrink a card below 132pt even when the only
/// alternative was overflowing. Both were reasonable-looking limits that quietly turned into "and
/// then it scrolls".
///
/// So the shape now degrades instead of surrendering. In order: full cards, smaller cards, cards
/// with no title, then rows of text. Within each tier the size is solved for rather than picked
/// from a list. The arithmetic guarantees a fit for any window count a machine can actually have,
/// and `--self-check` verifies it up to 400.
enum GridLayout {

    /// How the grid draws itself at a given density.
    enum Style: Equatable {
        /// Preview, app badge, title, app name.
        case card
        /// Preview and app badge only. The title is the first thing to go: at this size it is two
        /// truncated words, and the preview plus icon still identify a window.
        case compactCard
        /// A row of icon + title + app name. Holds far more per pixel than any card.
        case row
    }

    struct Plan: Equatable {
        let style: Style
        let columns: Int
        /// Card width in the two card styles; column width in `row`.
        let itemWidth: CGFloat
        let itemHeight: CGFloat
        /// True only when no layout could fit — a count no real machine reaches. The view scrolls
        /// then, because the alternative is hiding windows with no way to reach them.
        let overflows: Bool

        var isCompact: Bool { style == .row }
    }

    enum Card {
        /// 16:10, the shape of a window.
        static let previewAspect: CGFloat = 1.6
        static let padding: CGFloat = 16
        static let innerGap: CGFloat = 12
        /// Title plus app name.
        static let textHeight: CGFloat = 34
        static let gap: CGFloat = 16

        /// Largest a card may be. Above this they read as billboards — B26.
        static let maxWidth: CGFloat = 260
        /// Below this the title is two truncated words and is dropped — see `compactCard`.
        static let minTitledWidth: CGFloat = 150
        /// Below *this* a preview is a smudge, and rows of text carry more meaning per pixel.
        static let minWidth: CGFloat = 76

        static func height(forWidth width: CGFloat, titled: Bool) -> CGFloat {
            let inner = max(width - padding * 2, 1)
            let preview = inner / previewAspect
            let text = titled ? innerGap + textHeight : 0
            // Compact cards use half padding: at 90pt a 16pt border is a third of the card.
            let pad = titled ? padding * 2 : padding
            return preview + text + pad
        }
    }

    enum Compact {
        static let rowHeight: CGFloat = 30
        static let gap: CGFloat = 4
        /// Narrower than this and the title has no room beside the app name.
        static let minColumnWidth: CGFloat = 260
    }

    /// A section heading plus its rule and the gap below it.
    static let headingHeight: CGFloat = 38
    static let betweenSections: CGFloat = 32

    /// Solve for the largest layout that fits.
    ///
    /// `groupSizes` is how many windows are in each display section, in order. The height depends
    /// on the *division*, not only the total, because each section costs a heading and its own
    /// row boundary.
    static func plan(groupSizes: [Int], viewport: CGSize, hasHeadings: Bool) -> Plan {
        let total = groupSizes.reduce(0, +)
        // Columns are capped at the biggest section's size, not the total: each section lays out
        // its own rows, so a column beyond what any one of them holds is always empty.
        let largestGroup = groupSizes.max() ?? 1
        guard total > 0, viewport.width > 1, viewport.height > 1 else {
            return Plan(style: .card, columns: 1, itemWidth: Card.maxWidth,
                        itemHeight: Card.height(forWidth: Card.maxWidth, titled: true),
                        overflows: false)
        }

        // Widest first. The search walks *down* in 2pt steps rather than trying a handful of fixed
        // sizes, so the grid is always as large as it can be instead of as small as it is allowed
        // to be — the difference between a readable card and a scroll bar is often a few points.
        for titled in [true, false] {
            let floor = titled ? Card.minTitledWidth : Card.minWidth
            var width = Card.maxWidth
            while width >= floor {
                // **Never more columns than there are windows.** `LazyVGrid` fills fixed columns
                // left to right, so reserving seven columns for two cards left them hugging the
                // left edge with five empty slots beside them — the panel looked broken rather
                // than sparse. Seen in a screenshot; the arithmetic was right and the layout was
                // still wrong, which is the whole argument for looking.
                let columns = min(columnsThatFit(width: width, gap: Card.gap, in: viewport.width),
                                  largestGroup)
                if columns >= 1 {
                    let height = Card.height(forWidth: width, titled: titled)
                    let needed = stackHeight(groupSizes: groupSizes,
                                             columns: columns,
                                             itemHeight: height,
                                             gap: Card.gap,
                                             hasHeadings: hasHeadings)
                    if needed <= viewport.height {
                        return Plan(style: titled ? .card : .compactCard,
                                    columns: columns,
                                    itemWidth: width,
                                    itemHeight: height,
                                    overflows: false)
                    }
                }
                width -= 2
            }
        }

        // Cards cannot fit even without titles. Rows hold far more per pixel — 30pt against a
        // card's 60pt minimum — so this is where the grid changes kind rather than shrinking
        // into confetti.
        let maxRowColumns = max(1, min(Int(viewport.width / Compact.minColumnWidth), largestGroup))
        for columns in 1...maxRowColumns {
            let needed = stackHeight(groupSizes: groupSizes,
                                     columns: columns,
                                     itemHeight: Compact.rowHeight,
                                     gap: Compact.gap,
                                     hasHeadings: hasHeadings)
            if needed <= viewport.height {
                return Plan(style: .row, columns: columns,
                            itemWidth: viewport.width / CGFloat(columns),
                            itemHeight: Compact.rowHeight, overflows: false)
            }
        }

        // Nothing fits: hundreds of windows on a small display. The widest row layout needs the
        // least scrolling, and scrolling beats hiding windows with no way to reach them.
        return Plan(style: .row, columns: maxRowColumns,
                    itemWidth: viewport.width / CGFloat(maxRowColumns),
                    itemHeight: Compact.rowHeight, overflows: true)
    }

    private static func columnsThatFit(width: CGFloat, gap: CGFloat, in available: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        return max(0, Int((available + gap) / (width + gap)))
    }

    private static func stackHeight(groupSizes: [Int],
                                    columns: Int,
                                    itemHeight: CGFloat,
                                    gap: CGFloat,
                                    hasHeadings: Bool) -> CGFloat {
        var height: CGFloat = 0
        for (index, count) in groupSizes.enumerated() {
            if index > 0 { height += betweenSections }
            if hasHeadings { height += headingHeight }
            let rows = Int(ceil(Double(count) / Double(max(columns, 1))))
            height += CGFloat(rows) * itemHeight + CGFloat(max(rows - 1, 0)) * gap
        }
        return height
    }
}
