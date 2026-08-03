import AppKit
import SwiftUI

/// The floating strip.
///
/// The panel is built once at launch and only shown and hidden afterwards. Creating a window on
/// the hotkey costs tens of milliseconds and is felt as lag on the very keypress the app is
/// judged by — PLAN.md §11 budgets 16ms for the whole open, so window creation cannot be in it.
///
/// It is a `.nonactivatingPanel` because a switcher that takes focus would make the app it is
/// switching *away from* resign first, and the overlay would end up raising itself.
final class StripOverlay {

    private let model = StripModel()

    /// Set once at launch by the app delegate and forwarded to the model, so the view never
    /// needs to know the session exists.
    var onChoose: (Int) -> Void {
        get { model.onChoose }
        set { model.onChoose = newValue }
    }
    var onHover: (Int) -> Void {
        get { model.onHover }
        set { model.onHover = newValue }
    }
    var onSelectSearch: () -> Void {
        get { model.onSearchSelect }
        set { model.onSearchSelect = newValue }
    }
    var onCloseWindow: (Int) -> Void {
        get { model.onCloseWindow }
        set { model.onCloseWindow = newValue }
    }
    var onMinimizeWindow: (Int) -> Void {
        get { model.onMinimizeWindow }
        set { model.onMinimizeWindow = newValue }
    }

    /// **R3.** Whether "only this display" found nothing and everything is being shown instead.
    /// Supplied by the delegate so the overlay does not have to know the store exists.
    var displayFilterFellBack: (() -> Bool)?

    private var panel: NSPanel?
    private var frost: NSVisualEffectView?

    /// Tile geometry. The strip shrinks its tiles to fit rather than overflowing the screen;
    /// below the floor it would be unreadable, and that is where Phase 5's grid takes over.
    private enum Layout {
        /// Tiles are large and close to square — the reference is a row of generous panels, not
        /// a compact list. Below `minTileWidth` the icon and its label stop being readable at a
        /// glance, which is the whole point of a switcher; that is where Phase 5's grid takes over.
        static let tileWidth: CGFloat = 180
        static let minTileWidth: CGFloat = 110
        static let maxScreenFraction: CGFloat = 0.92
        /// How tall the whole panel may get, as a fraction of the usable screen. Rows are added
        /// to keep tiles readable, not to fill the display.
        static let maxScreenHeightFraction: CGFloat = 0.8
        /// Square wraps rather than shrinking without limit. One row is the switcher everybody
        /// knows; three is where a "row of windows" stops reading as a row at all, and beyond
        /// that the answer is Grid, not a fourth row of ever-smaller tiles.
        static let maxRows = 3
        /// Tile height as a fraction of its width. Square-ish, with room for the label.
        static let tileAspect: CGFloat = 1.0

        /// Previews get a wider tile but the tile stays **square**, which is what the mode is
        /// named for. A window is landscape, so its preview is fitted inside the square rather
        /// than cropped to fill it — some empty space above and below a wide window is a fair
        /// price for a row that keeps one rhythm. PLAN.md §10 keeps this as one constant so
        /// turning previews on does not reflow anything else.
        static let thumbnailTileWidth: CGFloat = 220

        /// One line above the row: how many windows there are, and a warning when hexad is not
        /// listening. Not a footer of hints — a hint repeated on every invocation is chrome, but
        /// "12 windows" is the answer to "is this list complete", which is different every time.
        static let headerHeight: CGFloat = 16
        /// The first-few-launches hint. **R4.**
        static let hintHeight: CGFloat = 14
    }

    private var isShowingThumbnails: Bool { Preferences.shared.showsThumbnails }
    private var idealTileWidth: CGFloat {
        isShowingThumbnails ? Layout.thumbnailTileWidth : Layout.tileWidth
    }
    /// Always square — see `thumbnailTileWidth`.
    private var tileAspect: CGFloat { Layout.tileAspect }

    // MARK: - Lifecycle

    func prepare() {
        guard panel == nil else { return }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Must appear over a full-screen app's Space, and must never be a ⌘` cycle target.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // `.sidebar`, the same material every other app in the family frosts with — not
        // `.hudWindow`, which is a different surface wearing the same blur. §3.
        let frost = OverlayChrome.makeFrost(cornerRadius: Theme.Radius.overlay)

        let hosting = NSHostingView(rootView: StripView(model: model))
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = frost.bounds
        frost.addSubview(hosting)

        // The frost is a *subview* of a plain container rather than the content view itself, so
        // the pop can scale it. Scaling a window's own content view fights AppKit's layout for
        // the layer's geometry; scaling a view we place ourselves does not.
        let container = NSView(frame: panel.contentLayoutRect)
        frost.frame = container.bounds
        frost.autoresizingMask = [.width, .height]
        container.addSubview(frost)

        panel.contentView = container
        self.panel = panel
        self.frost = frost
    }

    private func applySurface() {
        guard let frost else { return }
        OverlayChrome.applySurface(frost, isFrosted: Preferences.shared.isFrosted)
    }

    // MARK: - Showing

    /// Flash the panel edge when the cycle wraps. **R2** — wrapping is otherwise silent, so a long
    /// hold reads as the list having stopped rather than gone round.
    func flashWrap() {
        model.wrapFlash &+= 1
    }

    func show(items: [WindowItem],
              selected: Int,
              shortcutLabel: String,
              query: String = "",
              total: Int = 0,
              emptyReason: OverlayEmptyReason = .noMatch,
              appFilter: String? = nil) {
        prepare()
        guard let panel else { return }

        // An empty result is shown rather than suppressed. Filtering to nothing and having the
        // panel vanish reads as a crash; §11 says a list must say when it has nothing.
        model.items = items
        model.selected = selected
        model.shortcutLabel = shortcutLabel
        model.query = query
        model.total = max(total, items.count)
        model.emptyReason = emptyReason
        model.showsCount = Preferences.shared.showsCount
        // The overlay is the surface the user is actually looking at, so it is where "hexad is
        // not listening" belongs. Settings says so too, and Settings is not open.
        model.isListening = RuntimeStatus.shared.isListening
        model.notListeningReason = RuntimeStatus.shared.summary
        model.actionModifier = Preferences.shared.primaryBinding.actionModifierLabel
        model.appFilter = appFilter
        model.showsHoverActions = Preferences.shared.showsHoverActions
        model.separatesApps = Preferences.shared.separatesApps
        model.pinned = Preferences.shared.pinned
        // **R4.** The footer hint was removed as chrome, and a hint on every invocation is exactly
        // that. A hint on the first few launches is teaching, so it counts down and stops.
        model.showsHint = Preferences.shared.remainingHintSessions > 0
        model.displayFilterFellBack = displayFilterFellBack?() ?? false

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // The search tile takes a slot of its own, so it counts towards the fit.
        // An empty result still draws one tile, so the row is never zero-width.
        let slots = max(items.count, 1) + (Preferences.shared.isSearchEnabled ? 1 : 0)
        let plan = layout(slots: slots, within: visible)
        let tileWidth = plan.tileWidth
        model.tileWidth = tileWidth
        model.tileHeight = tileWidth * tileAspect
        model.rows = plan.rows
        model.perRow = plan.perRow
        model.showsThumbnails = isShowingThumbnails
        model.thumbnailFit = Preferences.shared.thumbnailFit
        model.showsTitles = Preferences.shared.showsTitles
        model.isSearchEnabled = Preferences.shared.isSearchEnabled

        // Fire the capture pass *after* the geometry is settled and before the panel is shown,
        // so images land into a layout that is already correct. It never blocks the open.
        if isShowingThumbnails {
            let size = CGSize(width: tileWidth, height: tileWidth * tileAspect)
            Task { @MainActor in
                ThumbnailProvider.shared.refresh(for: items, targetSize: size)
            }
        }

        let width = min(contentWidth(count: plan.perRow, tileWidth: tileWidth),
                        visible.width * Layout.maxScreenFraction)
        // The header is a line of its own, so the panel has to grow by exactly its height — a
        // strip that clips its own count line is worse than one that never had it.
        let header = (model.showsHeader ? Layout.headerHeight + Theme.Space.s8 : 0)
            + (model.showsHint ? Layout.hintHeight + Theme.Space.s8 : 0)
        let rows = CGFloat(plan.rows)
        let height = rows * tileWidth * tileAspect
            + (rows - 1) * Theme.Tile.gap
            + Theme.Space.overlayPadding * 2 + header

        let origin = NSPoint(x: visible.midX - width / 2, y: visible.midY - height / 2)
        applySurface()
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)),
                       display: true)

        // Re-show while the previous close is still animating out would otherwise inherit a
        // half-shrunk layer and a transparent window.
        guard let frost else { return }
        BackdropPanel.shared.show()
        OverlayChrome.present(panel: panel, scaling: frost, makeKey: false)
    }

    func select(_ index: Int, isOnSearch: Bool = false) {
        model.isOnSearch = isOnSearch
        model.selected = index
    }

    func hide() {
        BackdropPanel.shared.hide()
        guard let panel, let frost else { return }
        OverlayChrome.dismiss(panel: panel, scaling: frost)
    }

    // MARK: - Geometry

    private func contentWidth(count: Int, tileWidth: CGFloat) -> CGFloat {
        let tiles = CGFloat(count) * tileWidth
        let gaps = CGFloat(max(count - 1, 0)) * Theme.Tile.gap
        return tiles + gaps + Theme.Space.overlayPadding * 2
    }

    /// How many rows, how many tiles per row, and how wide each tile is.
    ///
    /// A single row that shrinks to fit is fine up to a point and hopeless past it: twenty windows
    /// on a laptop drove every tile to the 110pt floor, and a floor with no wrapping means the row
    /// simply runs off both edges of the screen. So Square wraps.
    ///
    /// The rule is the fewest rows that keep tiles at a readable width, capped at three. One row
    /// is the switcher everybody already knows and it is never given up unnecessarily; past three
    /// rows a "row of windows" is not a row any more, and the honest answer is Grid.
    private func layout(slots: Int, within visible: NSRect) -> (rows: Int,
                                                                perRow: Int,
                                                                tileWidth: CGFloat) {
        let maxHeight = visible.height * Layout.maxScreenHeightFraction
            - Theme.Space.overlayPadding * 2
            - (model.showsHeader ? Layout.headerHeight + Theme.Space.s8 : 0)

        var best: (rows: Int, perRow: Int, tileWidth: CGFloat)?

        for rows in 1...Layout.maxRows {
            let perRow = Int(ceil(Double(slots) / Double(rows)))
            let width = fittedTileWidth(count: perRow, within: visible.width)
            // Wrapping is only worth it if it actually buys width. It also has to fit vertically:
            // three rows of large tiles is taller than the screen, and a panel taller than the
            // display is worse than a narrow one.
            let stackHeight = CGFloat(rows) * width * tileAspect
                + CGFloat(rows - 1) * Theme.Tile.gap
            guard stackHeight <= maxHeight else { break }
            best = (rows, perRow, width)
            // Readable already — do not add a row for the sake of it.
            if width >= idealTileWidth * 0.85 { break }
        }

        // Nothing fits vertically at all: keep the single row and let it shrink. A crowded row is
        // still usable; no panel is not.
        return best ?? (1, slots, fittedTileWidth(count: slots, within: visible.width))
    }

    private func fittedTileWidth(count: Int, within screenWidth: CGFloat) -> CGFloat {
        let available = screenWidth * Layout.maxScreenFraction
            - Theme.Space.overlayPadding * 2
            - CGFloat(max(count - 1, 0)) * Theme.Tile.gap
        let ideal = available / CGFloat(max(count, 1))
        return min(idealTileWidth, max(Layout.minTileWidth, ideal))
    }
}

/// Why the switcher has nothing to show.
///
/// Three different problems used to show one blank panel, and they have three different fixes:
/// grant a permission, open a window, or clear the query. A user who reads "No windows" when the
/// truth is "Accessibility was revoked" concludes the app is broken rather than un-permitted.
enum OverlayEmptyReason {
    case noMatch
    case noWindows
    case noAccessibility

    var title: String {
        switch self {
        case .noMatch: return "No match"
        case .noWindows: return "No windows"
        case .noAccessibility: return "Not allowed"
        }
    }

    var systemImage: String {
        switch self {
        case .noMatch: return "questionmark.circle"
        case .noWindows: return "macwindow"
        case .noAccessibility: return "lock"
        }
    }

    /// The line under the title. Says what to *do*, not what happened.
    var detail: String {
        switch self {
        case .noMatch: return ""
        case .noWindows: return "Nothing open to switch to"
        case .noAccessibility: return "Grant Accessibility in Settings"
        }
    }
}

/// What the strip is currently showing. A class so the panel can mutate it between frames
/// without rebuilding the hosting view.
final class StripModel: ObservableObject {
    @Published var items: [WindowItem] = []
    @Published var selected: Int = 0
    @Published var shortcutLabel: String = "⌥Tab"
    @Published var tileWidth: CGFloat = 132
    @Published var tileHeight: CGFloat = 132
    @Published var showsThumbnails = false
    /// Published rather than read from `Preferences.shared` inside the view: a plain read
    /// gives SwiftUI nothing to invalidate on, so changing the setting redrew nothing and
    /// the control looked broken.
    @Published var thumbnailFit: Preferences.ThumbnailFit = .fill
    @Published var query: String = ""
    @Published var showsTitles = true
    @Published var isSearchEnabled = false
    /// True when the cycle has landed on the search tile rather than a window.
    @Published var isOnSearch = false
    /// The unfiltered count, so the header can say "3 of 12" while a query is narrowing it.
    @Published var total = 0
    @Published var showsCount = true
    @Published var isListening = true
    /// Why the tap is not running, in the same words Settings uses. `RuntimeStatus.summary`
    /// already distinguishes "Accessibility not granted" from "the tap could not start"; the
    /// overlay used to assert the first regardless.
    @Published var notListeningReason = ""
    @Published var emptyReason: OverlayEmptyReason = .noMatch
    /// The modifier that turns a letter into an action here — ⌥ while ⌘Tab is held.
    @Published var actionModifier = "⌥"
    /// How the tiles are wrapped. One row is the usual case; Square goes to two or three rather
    /// than shrinking tiles past the point of being readable. See `StripOverlay.layout`.
    @Published var rows = 1
    @Published var perRow = 1
    /// Bumped on every wrap, so the view can flash without being told when to stop. **R2.**
    @Published var wrapFlash = 0
    /// The app the list is narrowed to, if any. **N4.**
    @Published var appFilter: String?
    @Published var showsHoverActions = true
    @Published var separatesApps = true
    @Published var showsHint = false
    @Published var pinned = PinnedWindows()
    /// "Only this display" matched nothing, so everything is listed. **R3.**
    @Published var displayFilterFellBack = false

    /// Close and minimise, from the buttons on a hovered tile. **N3.**
    var onMinimizeWindow: (Int) -> Void = { _ in }

    /// Whether the line above the row is drawn at all. The warning ignores the count setting:
    /// somebody who turned the count off did not thereby ask not to be told the app is dead.
    var showsHeader: Bool { showsCount || !isListening }

    /// Mouse handling lives on the model because the panel is rebuilt never and the session is
    /// rebuilt never either — the closures are set once at launch and outlive every session.
    var onChoose: (Int) -> Void = { _ in }
    var onHover: (Int) -> Void = { _ in }
    /// Clicking the search tile moves the cycle onto it rather than committing —
    /// there is nothing there to switch to.
    var onSearchSelect: () -> Void = {}
    /// Middle-click: close that window, leave the switcher up.
    var onCloseWindow: (Int) -> Void = { _ in }
}
