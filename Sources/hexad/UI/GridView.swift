import SwiftUI
import UniformTypeIdentifiers

/// A dimmed backdrop with cards grouped by display, each section counted.
struct GridView: View {

    @ObservedObject var model: GridModel
    @ObservedObject private var thumbnails = ThumbnailProvider.shared
    let onChoose: (Int) -> Void
    var onHover: (Int) -> Void = { _ in }
    var onClose: (Int) -> Void = { _ in }
    /// Drag a card onto another display's section: move that window there.
    var onMove: (_ index: Int, _ screen: Int) -> Void = { _, _ in }

    /// Dragging between displays only means anything when there is another display to drag to.
    private var canMoveBetweenDisplays: Bool { NSScreen.screens.count > 1 }

    @State private var dropTarget: Int?

    private enum Layout {
        /// A comfortable reading width when the windows fit inside it — a handful of cards
        /// stretched across a 27-inch display is a row of billboards with a hole in the middle.
        ///
        /// **It is a preference, not a limit.** The first version treated it as a hard cap, which
        /// threw away a third of the available width on a wide display and turned "shrink the
        /// cards" into "scroll". When the grid needs the room it takes the whole screen.
        static let preferredContentWidth: CGFloat = 1180
        /// The rule under a section heading. A hairline, not a border: the sections are told
        /// apart by their headings, and a box around each one over a dimmed desktop reads as
        /// three windows rather than as one grid with three parts.
        static let ruleOpacity: CGFloat = 0.18
        /// Chrome the cards do not get to use. Measured from the views themselves rather than
        /// guessed — the layout solver has to subtract them before it can promise a fit.
        static let footerHeight: CGFloat = 72
        static let searchFieldHeight: CGFloat = 76
    }

    var body: some View {
        ZStack {
            // The dim itself is painted by the panel's container view — see GridController.
            // This is only the click target for dismissing by clicking away.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onChoose(-1) }

            VStack(spacing: Theme.Space.betweenSections) {
                // **No scroll view.** The whole promise of this mode is seeing every window at
                // once; anything below a fold is invisible, and reaching it costs a scroll, which
                // is slower than the ⌘Tab it replaced. The cards are sized to the viewport
                // instead — see GridLayout, which shrinks them, then changes their shape, and
                // only scrolls when no layout could have worked.
                GeometryReader { geometry in
                    let plan = plan(for: geometry.size)
                    content(plan)
                        // ↓ and ↑ move by a whole row, so the controller needs the column count
                        // the *layout solver* chose — not the model's own guess, which no longer
                        // decides anything. Pushed on change rather than read during layout,
                        // because mutating observed state inside a body is a runtime warning and
                        // an infinite invalidation loop waiting to happen.
                        .onChange(of: plan.columns, initial: true) { _, columns in
                            model.setEffectiveColumns(columns)
                        }
                        // The content takes exactly the width the solver planned against, so what
                        // is drawn and what was measured cannot disagree — that disagreement is
                        // what produced a scroll bar the arithmetic said was unnecessary.
                        .frame(width: contentWidth(for: geometry.size))
                        .padding(Theme.Space.panelPadding)
                        .frame(maxWidth: .infinity,
                               minHeight: geometry.size.height,
                               alignment: .center)
                        // Only when no layout could fit — hundreds of windows on a small display.
                        // Every case a real machine reaches has already been made to fit.
                        .ifCondition(plan.overflows) { view in
                            ScrollView { view }
                        }
                }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The root must claim the whole panel, or the backdrop is only as tall as the cards and
        // the desktop stays undimmed around them — which looks like a rendering failure.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    /// The viewport the cards actually get: the panel minus its padding, the footer, and the
    /// search field when there is one. Solving against the whole screen would produce a layout
    /// that fits everything except the chrome it has to sit inside.
    private func plan(for size: CGSize) -> GridLayout.Plan {
        let chrome = Theme.Space.panelPadding * 2
            + Layout.footerHeight
            + (model.isSearchEnabled ? Layout.searchFieldHeight : 0)
        return GridLayout.plan(groupSizes: model.groups.map(\.items.count),
                               viewport: CGSize(width: max(contentWidth(for: size), 1),
                                                height: max(size.height - chrome, 1)),
                               hasHeadings: model.groups.contains { !$0.name.isEmpty })
    }

    /// The width the cards actually get.
    ///
    /// The preferred width is used while the windows fit inside it, and abandoned the moment they
    /// do not: a wide display has the room, and refusing to use it is how the grid ended up
    /// scrolling on a screen with a third of its width unused.
    private func contentWidth(for size: CGSize) -> CGFloat {
        let full = size.width - Theme.Space.panelPadding * 2
        let preferred = min(full, Layout.preferredContentWidth - Theme.Space.panelPadding * 2)
        let chrome = Theme.Space.panelPadding * 2
            + Layout.footerHeight
            + (model.isSearchEnabled ? Layout.searchFieldHeight : 0)
        let height = max(size.height - chrome, 1)
        let groups = model.groups.map(\.items.count)
        let hasHeadings = model.groups.contains { !$0.name.isEmpty }

        // Take the narrower width only if it still lets everything fit as proper cards. Anything
        // denser than that, and the extra width is worth more than the tidier proportions.
        let atPreferred = GridLayout.plan(groupSizes: groups,
                                          viewport: CGSize(width: max(preferred, 1),
                                                           height: height),
                                          hasHeadings: hasHeadings)
        return atPreferred.style == .card ? preferred : full
    }

    @ViewBuilder
    private func content(_ plan: GridLayout.Plan) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.betweenSections) {
            // Grid was the one mode with no search at all, so the same three letters that find a
            // window in Square and List found nothing here.
            if model.isSearchEnabled { searchField }

            if model.flat.isEmpty {
                emptyState
            } else {
                ForEach(model.groups) { group in
                    section(group, plan: plan)
                }
            }
        }
    }

    // MARK: - Search

    /// A real text field, unlike Square's tile: the grid panel takes keyboard focus, so it can
    /// have one. Square cannot — the modifier release has to stay detectable.
    private var searchField: some View {
        HStack(spacing: Theme.Space.s12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.6))

            TextField("Find a window", text: $model.query)
                .textFieldStyle(.plain)
                .font(Font(Theme.Font.title))
                .foregroundStyle(.white)
                .accessibilityLabel("Find a window")

            if !model.query.isEmpty {
                Text("\(model.flat.count) of \(model.total)")
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, Theme.Space.s20)
        .padding(.vertical, Theme.Space.s12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(.white.opacity(Layout.ruleOpacity))
        )
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.s12) {
            Image(systemName: model.query.isEmpty ? "macwindow" : "questionmark.circle")
                .font(.system(size: 34, weight: .light))
            Text(model.query.isEmpty ? "No windows" : "No window matches")
                .font(Font(Theme.Font.bodyEmph))
            Text(model.query.isEmpty
                 ? "Nothing open to switch to"
                 : "Try part of the app name instead")
                .font(Font(Theme.Font.caption))
                .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.s40)
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(_ group: DisplayGrouping.Group, plan: GridLayout.Plan) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s16) {
            if !group.name.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    HStack(spacing: Theme.Space.s8) {
                        Text(group.name.uppercased())
                            .font(Font(Theme.Font.caption))
                            .tracking(0.6)

                        // Right-aligned, not trailing the name. A count that hugs the heading
                        // reads as part of the display's name; one at the far edge reads as a
                        // measurement of the row beneath it, which is what it is.
                        Spacer(minLength: Theme.Space.s16)

                        Text(group.items.count == 1 ? "1 window" : "\(group.items.count) windows")
                            .font(Font(Theme.Font.caption))
                    }
                    .foregroundStyle(.white.opacity(0.75))

                    Rectangle()
                        .fill(.white.opacity(Layout.ruleOpacity))
                        .frame(height: 1)
                }
            }

            if plan.style == .row {
                // Rows hold far more per pixel than cards — 30pt against a card's 60pt floor —
                // which is what lets the grid keep its promise of showing everything without a
                // scroll bar. Past one column of them, they run in columns too.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(),
                                                             spacing: Theme.Space.s16),
                                         count: plan.columns),
                          spacing: GridLayout.Compact.gap) {
                    ForEach(Array(group.items.enumerated()), id: \.offset) { offset, item in
                        let index = model.flatIndex(of: group, offset: offset)
                        GridCompactRow(item: item,
                                       query: model.query,
                                       isSelected: index == model.selected)
                            .onTapGesture { onChoose(index) }
                            .onHover { inside in if inside { onHover(index) } }
                            .onMiddleClick { onClose(index) }
                    }
                }
            } else {
                // **A maximum, not just a column count.** `.flexible()` with no ceiling divides
                // the whole screen between however many columns there are, so four windows on a
                // wide display produced cards about 470pt across — a grid of billboards. The tile
                // size comes from PLAN.md §10 (260 for a preview) and the row centres what is left
                // over rather than stretching to fill it.
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(plan.itemWidth),
                                                             spacing: GridLayout.Card.gap),
                                         count: plan.columns),
                          spacing: GridLayout.Card.gap) {
                    ForEach(Array(group.items.enumerated()), id: \.offset) { offset, item in
                        let index = model.flatIndex(of: group, offset: offset)
                        GridCard(item: item,
                                 query: model.query,
                                 siblingCount: model.windowCount(for: item),
                                 thumbnail: thumbnails.image(for: item),
                                 width: plan.itemWidth,
                                 height: plan.itemHeight,
                                 showsTitle: plan.style == .card,
                                 isSelected: index == model.selected)
                            .onTapGesture { onChoose(index) }
                            .onHover { inside in if inside { onHover(index) } }
                            .onMiddleClick { onClose(index) }
                            // A full-screen window owns a Space and cannot be repositioned, so
                            // it is not draggable at all rather than draggable and inert.
                            .ifCondition(canMoveBetweenDisplays && !item.isFullScreen) { card in
                                card.onDrag {
                                    NSItemProvider(object: "\(index)" as NSString)
                                }
                            }
                    }
                }
            }
        }
        // The whole section is the drop target, not each card: you are dropping onto a *display*,
        // and asking someone to hit a particular card to mean "this screen" would be a puzzle.
        .ifCondition(canMoveBetweenDisplays) { section in
            section
                .contentShape(Rectangle())
                .onDrop(of: [UTType.plainText], isTargeted: Binding(
                    get: { dropTarget == group.id },
                    set: { dropTarget = $0 ? group.id : nil }
                )) { providers in
                    handleDrop(providers, onto: group.id)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                        .strokeBorder(Color(nsColor: Palette.NS.accent),
                                      lineWidth: dropTarget == group.id ? 2 : 0)
                        .padding(-Theme.Space.s8)
                )
        }
    }

    /// The payload is the dragged card's flat index as text. `group.id` is the screen index —
    /// `DisplayGrouping` builds it that way — so the drop needs no lookup table.
    private func handleDrop(_ providers: [NSItemProvider], onto screen: Int) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let index = Int(text) else { return }
            DispatchQueue.main.async { onMove(index, screen) }
        }
        return true
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s12) {
            KeycapChip(text: "↑↓←→")
            Text("move")
            KeycapChip(text: "⏎")
            Text("switch")
            KeycapChip(text: "⌘W")
            Text("close")
            KeycapChip(text: "⌘Q")
            Text("quit")
            if canMoveBetweenDisplays {
                Text("· drag a card to another display to move it")
            }
            KeycapChip(text: "esc")
            Text("cancel")
        }
        .font(Font(Theme.Font.caption))
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, Theme.Space.s20)
        .padding(.vertical, Theme.Space.s12)
        .background(
            Capsule().fill(.ultraThinMaterial)
        )
        .padding(.bottom, Theme.Space.s32)
    }
}

/// A card: preview or app icon, an app badge, the window title, the app name. The selection is a
/// fill plus a ring plus a heavier title — never colour on its own. §12.
private struct GridCard: View {

    let item: WindowItem
    let query: String
    /// How many windows this app has in the list. Two or more earns an indicator, because a card
    /// that looks like "Safari" when there are four Safari windows is a card that lies.
    let siblingCount: Int
    let thumbnail: NSImage?
    /// Solved by `GridLayout` against the real viewport, not chosen here. The card cannot pick its
    /// own size without knowing how many others have to fit beside it.
    let width: CGFloat
    /// **Also solved, and load-bearing twice over.** A card left to size itself vertically takes
    /// its height from whatever aspect its preview happens to have, so a row came out ragged —
    /// a wide terminal capture next to a squarer Finder window next to an icon-only card, all
    /// different heights. It also made the solver's arithmetic a fiction: it computes one height
    /// per card and adds up rows from it, which is only true if every card actually is that tall.
    let height: CGFloat
    /// False once the cards are small enough that a title is two truncated words. The preview and
    /// the app badge still identify a window; a clipped title only adds noise.
    let showsTitle: Bool
    let isSelected: Bool

    /// 16:10, the shape of a window. Fixed so a row of cards keeps one rhythm whether or not the
    /// previews have landed yet — PLAN.md §10.
    private static let previewAspect: CGFloat = 1.6

    /// Scales with the card, so a badge is legible on a 260pt card and not the whole of a 90pt
    /// one. Below the titled floor the badge is the only thing naming the app.
    private var badgeSize: CGFloat { max(18, min(28, width * 0.16)) }
    private var padding: CGFloat {
        showsTitle ? GridLayout.Card.padding : GridLayout.Card.padding / 2
    }

    var body: some View {
        VStack(spacing: showsTitle ? Theme.Space.s12 : 0) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(Self.previewAspect, contentMode: .fit)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card,
                                                    style: .continuous))
                } else if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        // Scales with the card: a fixed 64pt icon is larger than the whole of a
                        // compact card, which clipped it into a coloured smear.
                        .frame(width: min(64, width * 0.5), height: min(64, width * 0.5))
                        .frame(maxWidth: .infinity)
                        .aspectRatio(Self.previewAspect, contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .frame(maxWidth: .infinity)
                        .aspectRatio(Self.previewAspect, contentMode: .fit)
                }
            }
            // The badge lives outside the preview branch so a card always says which app it
            // belongs to — with previews on, the preview is the only thing distinguishing two
            // cards, and two documents of one app look identical without it.
            .overlay(alignment: .bottomLeading) {
                if thumbnail != nil, let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: badgeSize, height: badgeSize)
                        .padding(showsTitle ? Theme.Space.s8 : Theme.Space.s4)
                }
            }
            .overlay(alignment: .topTrailing) { indicators }
            .opacity(item.isMinimized ? 0.45 : 1)

            // Dropped once the cards are too small to hold it. The alternative — keeping a title
            // that is two truncated words — costs the height that would otherwise have gone into
            // the preview, which is the part that still identifies the window.
            if showsTitle {
                VStack(spacing: 2) {
                    Text(MatchHighlight.title(item.displayTitle,
                                              query: query,
                                              base: .white,
                                              accent: Palette.NS.accent))
                        .font(Font(isSelected ? Theme.Font.bodyEmph : Theme.Font.body))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.subtitle)
                        .font(Font(Theme.Font.caption))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
            }
        }
        .padding(padding)
        // Height as well as width, so every card in a row is the same size and the solver's
        // row arithmetic describes what is actually drawn.
        .frame(width: width, height: height)
        // A card with no title still has to say what it is to a screen reader.
        .accessibilityElement(children: showsTitle ? .contain : .ignore)
        .accessibilityLabel(showsTitle ? "" : "\(item.displayTitle), \(item.subtitle)")
        // A frosted surface, not an 8% white wash. Over a wallpaper backdrop that wash was
        // invisible, so the cards read as icons and text floating loose on the desktop.
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .fill(isSelected
                      ? Color(nsColor: Palette.NS.accent).opacity(0.22)
                      : Color.black.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(isSelected
                              ? Color(nsColor: Palette.NS.accent)
                              : Color.white.opacity(0.12),
                              lineWidth: isSelected ? 2 : 1)
        )
        // Scoped to this card's own selection. Animating the enclosing section instead made
        // SwiftUI animate the *layout*, and a screenshot caught two whole grids cross-fading.
        // Motion here is affordance — the ring moving — never the furniture rearranging itself.
        .animation(.easeOut(duration: Theme.Motion.swap), value: isSelected)
    }

    /// Minimised, and "this app has more than one window open". Both are things a card cannot
    /// say by looking like itself.
    @ViewBuilder
    private var indicators: some View {
        HStack(spacing: Theme.Space.s4) {
            if siblingCount > 1 {
                Label("\(siblingCount)", systemImage: "square.on.square")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .medium))
            }
            // Full screen is worth a mark of its own: choosing one takes the whole desktop to
            // another Space, and the preview looks like any other maximised window.
            if item.isFullScreen {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
            }
            if item.isMinimized {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 11))
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, Theme.Space.s8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.45)))
        .padding(Theme.Space.s8)
        .opacity(siblingCount > 1 || item.isMinimized || item.isFullScreen ? 1 : 0)
    }
}

/// Above ~30 windows the cards stop being readable, so the grid becomes a list rather than
/// shrinking into confetti.
private struct GridCompactRow: View {

    let item: WindowItem
    let query: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s12) {
            if let icon = item.appIcon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            }
            Text(MatchHighlight.title(item.displayTitle,
                                      query: query,
                                      base: .white,
                                      accent: Palette.NS.accent))
                .font(Font(isSelected ? Theme.Font.bodyEmph : Theme.Font.body))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.s12)
            Text(item.subtitle)
                .font(Font(Theme.Font.caption))
                .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .padding(.vertical, Theme.Space.s8)
        .padding(.horizontal, Theme.Space.s16)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(isSelected
                      ? Color(nsColor: Palette.NS.accent).opacity(0.22)
                      : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
