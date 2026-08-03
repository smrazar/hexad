import AppKit

/// Spacing, radii, type and motion. Named values only — no inline literals anywhere else.
/// See ~/Developer/design-language.md §4–§8.
enum Theme {

    /// A 4pt grid. Default to the larger end; when unsure, add air.
    enum Space {
        static let s4: CGFloat = 4
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        static let s28: CGFloat = 28
        static let s32: CGFloat = 32
        static let s40: CGFloat = 40

        static let panelPadding = s28
        /// The switcher overlays, which sit tighter than a settings window. `panelPadding` is a
        /// document measure; at that size the strip reads as mostly empty frost.
        static let overlayPadding = s16
        static let cardPadding = s20
        static let rowVertical = s12 + s4     // 14 lives off-grid by design; composed, not magic
        static let rowHorizontal = s16
        static let betweenControls = s16
        static let betweenSections = s32
        static let betweenItems = s12
    }

    /// Always `.continuous` when drawn — macOS corners are superellipses and a circular
    /// corner reads as foreign.
    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 8
        static let panel: CGFloat = 10
        static let pill: CGFloat = 999

        /// hexad additions, for the full-screen overlay. The shared scale tops out at `panel`,
        /// which is right for a menu-bar popover and too tight for a floating overlay.
        /// Flagged in PLAN.md §10 to go back into design-tokens.json if they hold up.
        static let overlay: CGFloat = 28
        static let tile: CGFloat = 20
        /// A row in a list: the palette's rows, the grid's compact rows. Between `card` and
        /// `tile`, because a full-width row reads as boxy at `card` and as a lozenge at `tile`.
        /// One constant so a row and its selection can never round differently — which is exactly
        /// how the palette shipped with two radii visible in the same screenshot.
        static let row: CGFloat = 10
    }

    /// Control metrics from `design-language.md` §10. Named here so no component measures itself.
    enum Control {
        static let height: CGFloat = 30
        static let iconButton: CGFloat = 26
        /// The leading icon column in a settings row.
        static let rowIcon: CGFloat = 20
        /// The leading icon column in a list row.
        static let listIcon: CGFloat = 18
    }

    enum Font {
        static let display = NSFont.systemFont(ofSize: 24, weight: .semibold)
        static let title = NSFont.systemFont(ofSize: 16, weight: .semibold)
        static let headline = NSFont.systemFont(ofSize: 14, weight: .semibold)
        static let body = NSFont.systemFont(ofSize: 13, weight: .regular)
        static let bodyEmph = NSFont.systemFont(ofSize: 13, weight: .medium)
        static let caption = NSFont.systemFont(ofSize: 11, weight: .regular)
        static let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        static let monoSmall = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    }

    /// Subtle and quick. Nothing springs except a button release.
    enum Motion {
        /// Someone who has asked the system for less motion has asked every app, including this
        /// one. Read once — the setting cannot change without an app restart in practice, and
        /// checking it inside an animation block would put an IPC call on the draw path.
        static let isReduced: Bool =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        /// Any duration, with Reduce Motion honoured: the change still happens, it just stops
        /// travelling. Zero rather than "faster", because a shortened animation is still motion.
        static func duration(_ value: Double) -> Double { isReduced ? 0 : value }

        static let fast: TimeInterval = 0.12
        static let standard: TimeInterval = 0.16
        static let swap: TimeInterval = 0.14

        /// The overlay's open and close — a **pop**: a little fade and a little scale, together.
        ///
        /// Measured off the reference recording rather than guessed: the panel goes from absent
        /// to essentially full size inside two frames of a 30fps capture, so this is well under
        /// 100ms of scale with the fade riding along. A slow grow reads as a different, heavier
        /// app. Close is quicker still, because motion after the decision is just latency.
        enum Pop {
            static let inDuration: TimeInterval = 0.14
            static let outDuration: TimeInterval = 0.10
            /// Where the panel starts on the way in. Small — this is a pop, not a zoom.
            static let from: CGFloat = 0.92
            /// A single frame past 1, which is what makes it read as a pop rather than a fade
            /// that happens to move. Any more and it bounces, which §8 forbids.
            static let overshoot: CGFloat = 1.015
            /// Where it goes on the way out. It shrinks away from the user, never grows.
            static let to: CGFloat = 0.96
        }
    }

    /// The overlay tile. One aspect constant drives the whole strip and grid, so v2's
    /// landscape thumbnails do not reflow everything. PLAN.md §10.
    enum Tile {
        static let iconSize = CGSize(width: 180, height: 180)
        static let thumbnailSize = CGSize(width: 260, height: 164)
        /// The gap between tiles, from the Square mockup — roughly a tenth of a tile.
        static let gap: CGFloat = 18
        static let appIconPoints: CGFloat = 88
    }
}
