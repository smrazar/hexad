import SwiftUI

/// What the list is showing. Filtering lives here rather than in the view so the controller can
/// act on the selection without asking SwiftUI what it currently displays.
final class PaletteModel: ObservableObject {

    @Published var query: String = "" {
        didSet { refilter() }
    }
    @Published private(set) var results: [WindowItem] = []
    @Published var selected: Int = 0
    /// The unfiltered count, so the footer can say "3 of 12".
    @Published private(set) var total = 0

    private var source: [WindowItem] = []

    var selectedItem: WindowItem? {
        results.indices.contains(selected) ? results[selected] : nil
    }

    func reset(with items: [WindowItem]) {
        source = items
        total = items.count
        query = ""
        refilter()
        // Index 1 is the previous window, as in every other mode — unless the user asked to land
        // on what is already in front. Starting at 0 here meant List alone opened on the window
        // you were already in, so a single ⏎ switched to nothing.
        selected = results.count > 1 && !Preferences.shared.opensOnActiveApp ? 1 : 0
    }

    func replaceSource(_ items: [WindowItem]) {
        source = items
        total = items.count
        refilter()
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
    }

    private func refilter() {
        // Match on both the window title and its app name — people search for "safari" as often
        // as for the page they left open in it.
        results = FuzzyMatch.rank(source, query: query) { "\($0.appName) \($0.displayTitle)" }
        if selected >= results.count { selected = max(results.count - 1, 0) }
    }
}

/// List mode — a vertical list of windows with a preview of the selected one beside it.
///
/// The split is the point: the list answers "which windows exist" and the pane answers "is this
/// the one I meant", and a switcher that can only do the first makes you commit to find out.
struct PaletteView: View {

    @ObservedObject var model: PaletteModel
    @ObservedObject private var preferences = Preferences.shared
    @FocusState private var isFieldFocused: Bool

    /// Chosen so the list stays readable at its narrowest while the preview is big enough to
    /// recognise a window by its contents rather than by its shape.
    private static let listWidth: CGFloat = 340

    var onChoose: (Int) -> Void = { _ in }
    /// Middle-click closes that row's window and leaves the list up.
    var onClose: (Int) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if preferences.isSearchEnabled {
                field
                divider
            }

            HStack(spacing: 0) {
                list
                    .frame(width: preferences.showsThumbnails ? Self.listWidth : nil)
                    .frame(maxWidth: preferences.showsThumbnails ? nil : .infinity)

                // The preview earns its space only when there is something to put in it. With
                // previews off the list takes the full width rather than sitting beside a
                // permanently empty panel.
                if preferences.showsThumbnails {
                    Rectangle()
                        .fill(Color(nsColor: Palette.NS.border))
                        .frame(width: 1)
                    PreviewPane(item: model.selectedItem)
                }
            }
            footer
        }
        .onAppear { isFieldFocused = true }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: Palette.NS.border))
            .frame(height: 1)
    }

    // MARK: - Field

    private var field: some View {
        HStack(spacing: Theme.Space.s12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color(nsColor: Palette.NS.textTertiary))

            TextField("Find a window", text: $model.query)
                .textFieldStyle(.plain)
                .font(Font(Theme.Font.title))
                .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))
                .focused($isFieldFocused)
                .accessibilityLabel("Find a window")
        }
        .padding(.horizontal, Theme.Space.s20)
        .padding(.vertical, Theme.Space.s16)
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.results.enumerated()), id: \.offset) { offset, item in
                        PaletteRow(item: item,
                                   query: model.query,
                                   isSelected: offset == model.selected)
                            .id(offset)
                            // Hover selects and click commits, the same pair as every other
                            // mode — the preview then follows the pointer for free.
                            .onHover { inside in
                                if inside { model.selected = offset }
                            }
                            .onTapGesture { onChoose(offset) }
                            .onMiddleClick { onClose(offset) }
                    }
                }
                .padding(.vertical, Theme.Space.s8)
            }
            .onChange(of: model.selected) { _, index in
                withAnimation(.easeOut(duration: Theme.Motion.fast)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .overlay {
                if model.results.isEmpty { emptyState }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// A large light glyph, a `bodyEmph` title, a caption. Never a blank rectangle. §10.
    private var emptyState: some View {
        VStack(spacing: Theme.Space.s12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color(nsColor: Palette.NS.textTertiary))
            Text("No window matches")
                .font(Font(Theme.Font.bodyEmph))
                .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))
            Text("Try part of the app name instead")
                .font(Font(Theme.Font.caption))
                .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.s12) {
            hint("↑↓", "move")
            hint("⏎", "switch")
            hint("⌘W", "close")
            hint("⌘Q", "quit")
            Spacer()
            // The count belongs beside the escape hatch: it answers "is this everything?", which
            // is the question someone asks right before giving up and pressing Esc.
            Text(countLabel)
                .font(Font(Theme.Font.caption))
                .foregroundStyle(Color(nsColor: Palette.NS.textTertiary))
            hint("esc", "cancel")
        }
        .padding(.horizontal, Theme.Space.s20)
        .padding(.vertical, Theme.Space.s12)
        .background(
            Rectangle()
                .fill(Color(nsColor: Palette.NS.border))
                .frame(height: 1),
            alignment: .top
        )
    }

    /// "12 windows", or "3 of 12" while a query is narrowing it — the second number says the
    /// rest are still there rather than gone.
    private var countLabel: String {
        let shown = model.results.count
        if !model.query.isEmpty && shown != model.total {
            return "\(shown) of \(model.total)"
        }
        return shown == 1 ? "1 window" : "\(shown) windows"
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: Theme.Space.s4 + 2) {
            KeycapChip(text: key)
            Text(label)
                .font(Font(Theme.Font.caption))
                .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
        }
    }
}

/// The selected window, shown large beside the list.
private struct PreviewPane: View {

    let item: WindowItem?
    @ObservedObject private var thumbnails = ThumbnailProvider.shared

    var body: some View {
        VStack(spacing: Theme.Space.s12) {
            Spacer(minLength: 0)
            content
            if let item {
                VStack(spacing: 2) {
                    Text(item.displayTitle)
                        .font(Font(Theme.Font.bodyEmph))
                        .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.subtitle)
                        .font(Font(Theme.Font.caption))
                        .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.s20)
        .animation(.easeOut(duration: Theme.Motion.fast), value: thumbnails.generation)
    }

    @ViewBuilder
    private var content: some View {
        if let item, let image = thumbnails.image(for: item) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Color(nsColor: Palette.NS.border))
                )
        } else if let item, let icon = item.appIcon {
            // A capture that has not landed yet falls back to the icon rather than to blank
            // space, so the pane never looks like it failed.
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
        } else {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color(nsColor: Palette.NS.textTertiary))
        }
    }
}

/// Leading icon · title + secondary hint · selected row in `accentSoft`. §10, list row.
private struct PaletteRow: View {

    let item: WindowItem
    /// The live query, so the row can mark the letters that put it here. The list ranks fuzzily
    /// and showed no reason for its order, which reads as arbitrary until the matches are marked.
    let query: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s12) {
            if let icon = item.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color(nsColor: Palette.NS.surfaceSecondary))
                    .frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(MatchHighlight.title(item.displayTitle,
                                          query: query,
                                          base: Palette.NS.textPrimary))
                    .font(Font(isSelected ? Theme.Font.bodyEmph : Theme.Font.body))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.isMinimized ? "\(item.appName) · minimised" : item.subtitle)
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Space.s8)
        }
        .padding(.vertical, Theme.Space.s8)
        .padding(.horizontal, Theme.Space.s12)
        // Selection is a wash **and** a thin ring, at one radius — design-language.md §2 forbids a
        // solid fill, and the ring is what makes the selected row read as selected rather than
        // merely tinted. The wash, the ring and the row all round by `Radius.row`; using two
        // different radii here is the inconsistency visible in the reported screenshot.
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(Color(nsColor: isSelected ? Palette.NS.accentSoft : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(Color(nsColor: Palette.NS.accent),
                              lineWidth: isSelected ? 1 : 0)
        )
        .padding(.horizontal, Theme.Space.s8)
        .contentShape(Rectangle())
    }
}
