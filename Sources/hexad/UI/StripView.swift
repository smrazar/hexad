import SwiftUI

/// A row of tiles, one per window, with the current one ringed in the accent.
struct StripView: View {

    @ObservedObject var model: StripModel
    @ObservedObject private var thumbnails = ThumbnailProvider.shared

    /// **R2.** Driven by a counter rather than a boolean, so repeated wraps each flash — a bool
    /// that is already true cannot animate again.
    @State private var wrapGlow = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            if model.showsHeader { header }
            row
            if model.showsHint { hint }
        }
        .padding(Theme.Space.overlayPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The wrap flash is a ring on the panel itself, not on a tile: it is saying something
        // about the *list* — that it went round — rather than about any one window.
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.overlay, style: .continuous)
                .strokeBorder(Color(nsColor: Palette.NS.accent), lineWidth: wrapGlow ? 2 : 0)
                .opacity(wrapGlow ? 1 : 0)
                .allowsHitTesting(false)
        )
        .onChange(of: model.wrapFlash) { _, _ in
            guard !Theme.Motion.isReduced else { return }
            withAnimation(.easeOut(duration: Theme.Motion.fast)) { wrapGlow = true }
            withAnimation(.easeIn(duration: Theme.Motion.standard).delay(Theme.Motion.fast)) {
                wrapGlow = false
            }
        }
        // Redraw when a capture lands. The provider publishes a counter rather than the images
        // themselves, because diffing a dictionary of NSImage on every frame is not free.
        .animation(.easeOut(duration: Theme.Motion.fast), value: thumbnails.generation)
    }

    /// One line above the row: how complete the list is, and whether hexad is listening at all.
    ///
    /// The count is the cheapest confidence the app can give — "12 windows" tells you the list is
    /// whole before you start tabbing, and a list quietly missing something looks exactly like a
    /// complete one. The warning is here rather than only in Settings because Settings is not the
    /// window anybody is looking at when the app has stopped working.
    /// **R4.** Shown for the first few launches only, then never again — the difference between
    /// teaching and furniture is whether it stops.
    private var hint: some View {
        HStack(spacing: Theme.Space.s12) {
            Text("hold to cycle · release to switch")
            Text("↓ this app only")
            if Preferences.shared.quickLookEnabled { Text("space to preview") }
            Text("\(model.actionModifier)P pin")
        }
        .font(Font(Theme.Font.caption))
        .foregroundStyle(Color(nsColor: Palette.NS.textTertiary))
        .padding(.horizontal, Theme.Space.s4)
        .frame(height: 14)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s8) {
            // **N4.** When the list is narrowed to one app, the header has to say so — otherwise
            // a switcher showing four windows when the machine has forty looks broken.
            if let app = model.appFilter {
                Label(app, systemImage: "line.3.horizontal.decrease.circle.fill")
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(Color(nsColor: Palette.NS.accent))
                Text("← for everything")
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(Color(nsColor: Palette.NS.textTertiary))
            } else if !model.isListening {
                // The *reason*, not a guess at it. This used to hardcode "Accessibility is
                // missing", which is only one of the two ways the tap fails — the other is that
                // Accessibility is granted and the tap could not be created anyway. Settings has
                // always said which; the overlay asserted the wrong one and was caught doing it
                // in a screenshot, listing 24 windows while claiming it had no permission to.
                Label(model.notListeningReason, systemImage: "exclamationmark.triangle.fill")
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))
            } else if model.displayFilterFellBack {
                // **R3.** The filter is on and matched nothing, so everything is listed. Falling
                // back silently is its own lie — the setting says one thing and the panel shows
                // another, with no way to tell that from the filter simply not working.
                Label("Nothing on this display — showing everything",
                      systemImage: "display.2")
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
            } else if model.showsCount {
                Text(countLabel)
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
            }

            Spacer(minLength: Theme.Space.s8)

            if model.isListening, model.showsCount, !model.items.isEmpty {
                Text("\(model.actionModifier)W close · \(model.actionModifier)Q quit")
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(Color(nsColor: Palette.NS.textTertiary))
            }
        }
        .frame(height: 16)
        .padding(.horizontal, Theme.Space.s4)
    }

    /// "12 windows" normally, "3 of 12" while a query is narrowing it — the second number is what
    /// says the rest are still there rather than gone.
    private var countLabel: String {
        let shown = model.items.count
        if !model.query.isEmpty && shown != model.total {
            return "\(shown) of \(model.total)"
        }
        return shown == 1 ? "1 window" : "\(shown) windows"
    }

    /// One row, or two or three when a single row would shrink the tiles past readable.
    ///
    /// The tiles are laid out as one flat sequence — the search tile, then the windows — and cut
    /// into rows of `perRow`. Cutting the *sequence* rather than grouping by anything meaningful
    /// is deliberate: the cycle order has to read left-to-right then down, exactly as text does,
    /// or tabbing through jumps around the panel.
    private var row: some View {
        VStack(alignment: .leading, spacing: Theme.Tile.gap) {
            ForEach(Array(rowsOfSlots.enumerated()), id: \.offset) { _, slots in
                HStack(spacing: Theme.Tile.gap) {
                    ForEach(slots, id: \.self) { slot in
                        tile(for: slot)
                    }
                }
            }
        }
        .animation(.easeOut(duration: Theme.Motion.swap), value: model.selected)
    }

    /// A slot is either the search tile, the empty tile, or a window at an index.
    private enum Slot: Hashable {
        case search
        case empty
        case window(Int)
    }

    private var rowsOfSlots: [[Slot]] {
        var slots: [Slot] = []
        // The search tile leads the row whenever search is on, so "you can type here" is visible
        // before anyone types. It is deliberately **not** selectable: cycling through a text
        // field to reach a window would put a dead stop in the middle of the gesture the whole
        // mode is built around.
        if model.isSearchEnabled { slots.append(.search) }
        if model.items.isEmpty {
            slots.append(.empty)
        } else {
            slots += model.items.indices.map(Slot.window)
        }

        let perRow = max(model.perRow, 1)

        // **N6.** The list is two tiers — windows, then running apps with no window — and in one
        // flat sequence the boundary is invisible: an app icon sits among window tiles looking
        // like a window that failed to render a preview. Given its own row it reads at a glance
        // as the different kind of thing it is.
        //
        // Only when it does not cost a row that was otherwise fitting: on a crowded screen the
        // tidier grouping is not worth pushing a tile off the edge.
        if model.separatesApps,
           let firstApp = model.items.firstIndex(where: \.isAppOnly),
           firstApp > 0 {
            let lead = slots.count - model.items.count
            let split = lead + firstApp
            let windows = Array(slots[..<split])
            let apps = Array(slots[split...])
            let windowRows = Int(ceil(Double(windows.count) / Double(perRow)))
            let appRows = Int(ceil(Double(apps.count) / Double(perRow)))
            if windowRows + appRows <= model.rows {
                return chunk(windows, by: perRow) + chunk(apps, by: perRow)
            }
        }

        return chunk(slots, by: perRow)
    }

    private func chunk(_ slots: [Slot], by size: Int) -> [[Slot]] {
        guard !slots.isEmpty else { return [] }
        return stride(from: 0, to: slots.count, by: size).map { start in
            Array(slots[start..<min(start + size, slots.count)])
        }
    }

    @ViewBuilder
    private func tile(for slot: Slot) -> some View {
        switch slot {
        case .search:
            SearchTile(query: model.query,
                       width: model.tileWidth,
                       height: model.tileHeight,
                       isActive: !model.query.isEmpty)
        case .empty:
            EmptyTile(reason: model.emptyReason,
                      query: model.query,
                      width: model.tileWidth,
                      height: model.tileHeight)
        case .window(let offset):
            if model.items.indices.contains(offset) {
                let item = model.items[offset]
                StripTile(item: item,
                          query: model.query,
                          width: model.tileWidth,
                          height: model.tileHeight,
                          showsThumbnail: model.showsThumbnails,
                          fit: model.thumbnailFit,
                          showsTitle: model.showsTitles,
                          // Reading through the provider rather than holding a copy means a
                          // capture that lands after the strip opened swaps straight in.
                          thumbnail: model.showsThumbnails
                              ? thumbnails.image(for: item)
                              : nil,
                          isSelected: offset == model.selected,
                          pinnedSlot: model.pinned.slot(for: item.identity),
                          showsHoverActions: model.showsHoverActions,
                          onClose: { model.onCloseWindow(offset) },
                          onMinimize: { model.onMinimizeWindow(offset) })
                    // A switcher you cannot click is a switcher that ignores the hand already on
                    // the mouse. Hover selects, click commits — the same two gestures every list
                    // on the platform uses.
                    .onHover { inside in
                        if inside { model.onHover(offset) }
                    }
                    .onTapGesture { model.onChoose(offset) }
                    // Middle-click closes the window and leaves the switcher up — what it means
                    // everywhere else tabs exist.
                    .onMiddleClick { model.onCloseWindow(offset) }
            }
        }
    }
}

private struct StripTile: View {

    let item: WindowItem
    /// The live query, so the title can show *which* letters put this tile in the list. The
    /// ranking is fuzzy, and without the marks its order reads as arbitrary.
    let query: String
    let width: CGFloat
    let height: CGFloat
    let showsThumbnail: Bool
    let fit: Preferences.ThumbnailFit
    let showsTitle: Bool
    let thumbnail: NSImage?
    let isSelected: Bool
    /// The fixed slot this window is pinned to, or nil. **N1** — a pin the user cannot see is a
    /// pin they will assume did not take.
    var pinnedSlot: Int?
    var showsHoverActions = true
    var onClose: () -> Void = {}
    var onMinimize: () -> Void = {}

    /// **N3.** ⌘W and ⌘M exist and nobody discovers them. Buttons on the hovered tile are how
    /// every tab strip on the platform teaches the same two actions.
    @State private var isHovering = false

    private var iconSize: CGFloat { min(Theme.Tile.appIconPoints, min(width, height) * 0.5) }
    /// The badge over a preview. Scales with the tile rather than sitting at a fixed 28pt, which
    /// was legible on a 220pt tile and a speck on a large one — and the badge is the only thing
    /// saying which app a preview belongs to.
    private var badgeSize: CGFloat { max(28, min(width, height) * 0.26) }
    /// How much room the title bar takes along the bottom, so nothing is laid out underneath it.
    private var titleBarHeight: CGFloat { showsTitle ? 22 : 0 }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The content must fill the tile, or the ZStack shrinks to fit the app icon and the
            // title bar lands across the middle of the tile instead of along its bottom edge.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A bar along the bottom edge of the tile, the full width of it. The previous version
            // floated a centred capsule inside the tile, which read as a button sitting on the
            // preview rather than as the window's name.
            if showsTitle {
                Text(MatchHighlight.title(item.displayTitle,
                                          query: query,
                                          base: isSelected
                                              ? Palette.NS.textPrimary
                                              : Palette.NS.textSecondary))
                    .font(Font(Theme.Font.caption))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, Theme.Space.s8)
                    .padding(.vertical, Theme.Space.s4)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .topTrailing) {
            // Minimised needs a mark of its own. Dimming alone is colour carrying meaning, which
            // §12 forbids, and it is indistinguishable from a dark window. Full screen needs one
            // for a different reason: choosing it moves the desktop to another Space.
            HStack(spacing: Theme.Space.s4) {
                if item.isFullScreen {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11))
                }
                if item.isMinimized {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 13))
                }
            }
            .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
            .padding(Theme.Space.s8)
        }
        // The pin badge sits opposite the state marks, and carries its slot number — the number
        // is the whole point, because ⌘3 is only useful if you can see which tile is 3.
        .overlay(alignment: .topLeading) {
            if let pinnedSlot {
                Label("\(pinnedSlot)", systemImage: "pin.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Palette.NS.onAccent))
                    .padding(.horizontal, Theme.Space.s4 + 2)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: Palette.NS.accent)))
                    .padding(Theme.Space.s8)
            }
        }
        // Actions appear on hover only, and only on a real window — an app-only row has no window
        // to close, and offering the button anyway would be a button that does nothing.
        .overlay(alignment: .bottomTrailing) {
            if showsHoverActions, isHovering, !item.isAppOnly {
                HStack(spacing: Theme.Space.s4) {
                    TileActionButton(systemImage: "minus", help: "Minimise", action: onMinimize)
                    TileActionButton(systemImage: "xmark", help: "Close", action: onClose)
                }
                .padding(Theme.Space.s8)
                .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Theme.Motion.fast), value: isHovering)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                // Every tile carries a surface, not just the selected one. A row of floating
                // icons on frosted glass has no rhythm; the panels are what make it read as a
                // set of things you are choosing between.
                .fill(Color(nsColor: isSelected
                            ? Palette.NS.accentSoft
                            : Palette.NS.surfaceSecondary))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                // 2 for the selection, 1 for everything else. Any heavier and a row of tiles
                // reads as a grid of boxes rather than a set of windows.
                .strokeBorder(Color(nsColor: isSelected
                                    ? Palette.NS.accent
                                    : Palette.NS.border),
                              lineWidth: isSelected ? 2 : 1)
        )
    }

    /// A preview when there is one, the app icon when there is not.
    ///
    /// Previews arrive asynchronously, so this falls back rather than reserving an empty space:
    /// a tile that is blank until a screenshot lands looks broken for the exact fraction of a
    /// second the user is looking at it.
    @ViewBuilder
    private var content: some View {
        if showsThumbnail, let thumbnail {
            preview(thumbnail)
        } else {
            icon
        }
    }

    private func preview(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            // The tile is square and a window is not, so something has to give. Fill crops the
            // sides and keeps the tile full; Fit shows the whole window inside letterbox bars.
            // The user picks — Settings ▸ Appearance. Square is the only mode that has to ask.
            // The frame is the tile itself — square. A window is landscape, so Fill scales it
            // until the *height* matches and crops the sides; Fit shows all of it with bars above
            // and below. Filling by width would leave the tile short, which is what "the fill
            // dimension should be height" is asking to stop.
            .aspectRatio(contentMode: fit == .fill ? .fill : .fit)
            .frame(width: width, height: height)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if let appIcon = item.appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: badgeSize, height: badgeSize)
                        .padding(Theme.Space.s8)
                        .padding(.bottom, titleBarHeight)
                }
            }
            .opacity(item.isMinimized ? 0.45 : 1)
    }

    private var icon: some View {
        ZStack {
            if let appIcon = item.appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconSize, height: iconSize)
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color(nsColor: Palette.NS.surfaceSecondary))
                    .frame(width: iconSize, height: iconSize)
            }
        }
        // Centred in the space *above* the title bar, not in the tile — otherwise the bar covers
        // the bottom of the icon it is labelling.
        .padding(.bottom, titleBarHeight)
        // A minimized window is still switchable, and looking identical to an open one is how
        // a user ends up thinking the switcher lost track of it.
        .opacity(item.isMinimized ? 0.45 : 1)
    }
}

/// A small round button on a hovered tile. **N3.**
///
/// Deliberately not a `Button` with a bordered style: the overlay never becomes key, so a real
/// button renders in its inactive appearance and reads as disabled. A shape with a tap gesture
/// looks right and behaves the same.
struct TileActionButton: View {

    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color(nsColor: isHovering
                                   ? Palette.NS.onAccent
                                   : Palette.NS.textPrimary))
            .frame(width: 18, height: 18)
            .background(
                Circle().fill(Color(nsColor: isHovering
                                    ? Palette.NS.accent
                                    : Palette.NS.surface))
            )
            .overlay(Circle().strokeBorder(Color(nsColor: Palette.NS.border)))
            .onHover { isHovering = $0 }
            .onTapGesture(perform: action)
            .accessibilityLabel(help)
            .accessibilityAddTraits(.isButton)
            .help(help)
    }
}

/// The first tile in Square: where typing goes.
///
/// Shows the query once there is one, and an invitation before that. It is a display, not a text
/// field — the strip never takes keyboard focus, because releasing the modifier has to stay
/// detectable, so the characters arrive through the event tap and land here.
private struct SearchTile: View {

    let query: String
    let width: CGFloat
    let height: CGFloat
    let isActive: Bool

    var body: some View {
        VStack(spacing: Theme.Space.s8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: min(width, height) * 0.28, weight: .light))
                .foregroundStyle(Color(nsColor: isActive
                                       ? Palette.NS.accent
                                       : Palette.NS.textSecondary))
            Text(query.isEmpty ? "Type…" : query)
                .font(Font(Theme.Font.bodyEmph))
                .foregroundStyle(Color(nsColor: isActive
                                       ? Palette.NS.textPrimary
                                       : Palette.NS.textSecondary))
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, Theme.Space.s8)
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .fill(Color(nsColor: isActive
                            ? Palette.NS.accentSoft
                            : Palette.NS.surfaceSecondary))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(Color(nsColor: isActive
                                    ? Palette.NS.accent
                                    : Palette.NS.border),
                              lineWidth: 1)
        )
    }
}

/// Shown in place of the windows when there is nothing to show — and it says which nothing.
///
/// A tile rather than a line of text, so the row keeps its shape and the panel keeps its size — a
/// strip that changes height as you type reads as a glitch rather than as a result.
///
/// The three cases have three different fixes: clear the query, open a window, grant a permission.
/// One blank tile for all three is how a permission problem gets mistaken for a broken app.
private struct EmptyTile: View {

    let reason: OverlayEmptyReason
    let query: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(spacing: Theme.Space.s8) {
            Image(systemName: reason.systemImage)
                .font(.system(size: min(width, height) * 0.24, weight: .light))
                .foregroundStyle(Color(nsColor: Palette.NS.textTertiary))
            Text(reason.title)
                .font(Font(Theme.Font.bodyEmph))
                .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
            // A failed search shows the query back, because the usual cause is a typo the user
            // cannot see — the field is a tile, not a cursor. Anything else shows the fix.
            Text(reason == .noMatch ? query : reason.detail)
                .font(Font(reason == .noMatch ? Theme.Font.monoSmall : Theme.Font.caption))
                .foregroundStyle(Color(nsColor: Palette.NS.textTertiary))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.head)
                .padding(.horizontal, Theme.Space.s8)
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .fill(Color(nsColor: Palette.NS.surfaceSecondary))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(Color(nsColor: Palette.NS.border), lineWidth: 1)
        )
    }
}
