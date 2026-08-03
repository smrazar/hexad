import AppKit
import SwiftUI

/// The grid — every window at once, over a dimmed desktop.
///
/// Unlike the strip this is not a held-modifier gesture. It is a place you land, look around and
/// choose from, so it takes focus, stays until dismissed, and accepts arrows and clicks.
final class GridController {

    /// Enough to push the desktop back without hiding what is behind the cards.
    static let backdropOpacity: CGFloat = 0.45

    private let model = GridModel()
    private let store: WindowStore
    private var panel: KeyablePanel?
    private var hosting: NSHostingView<GridView>?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    /// Called whenever this closes, by any route. The event tap uses it to disarm
    /// release-to-commit.
    var onClose: () -> Void = {}

    private(set) var isOpen = false

    init(store: WindowStore) {
        self.store = store
    }

    func prepare() {
        guard panel == nil else { return }
        let panel = KeyablePanel(contentRect: NSScreen.main?.frame ?? .zero,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.isOpaque = false
        // The dim is the window's own background. Painting it in a subview — layer-backed or
        // SwiftUI — depends on that view actually receiving the panel's bounds, and twice it
        // did not: the backdrop came out only as tall as the cards. A window background cannot
        // be the wrong size.
        // The dim used to live here as the window's own background. It is now the shared
        // BackdropPanel, so all three modes get the same choice of backdrop rather than the grid
        // having one nobody else could have.
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: GridView(model: model,
                                                       onChoose: { [weak self] index in
            self?.model.selected = index
            self?.close(commit: true)
        }, onHover: { [weak self] index in
            self?.model.selected = index
        }, onClose: { [weak self] index in
            guard let self, self.model.flat.indices.contains(index) else { return }
            self.act(on: self.model.flat[index], self.store.close)
        }, onMove: { [weak self] index, screen in
            guard let self, self.model.flat.indices.contains(index) else { return }
            let item = self.model.flat[index]
            guard self.store.move(item, toScreen: screen) else { return }
            // Re-read so the card lands in the section it was dropped on. Without this the grid
            // keeps showing it under the old display until something else triggers a rebuild,
            // which reads as the drag having failed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.isOpen else { return }
                self.store.rebuild()
                self.model.replaceSource(self.store.snapshot())
            }
        }))
        // A hosting view with no sizing options publishes no size of its own, so handing it
        // straight to `contentView` leaves it at zero and the panel renders nothing at all —
        // alive, key, and invisible. It goes inside a container that resizes with the window.
        hosting.sizingOptions = []
        let container = NSView(frame: panel.contentLayoutRect)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        self.panel = panel
        self.hosting = hosting
    }

    func toggle() {
        isOpen ? close(commit: false) : open()
    }

    /// Move the selection from outside — the event tap, when the binding is pressed again while
    /// the grid is already up. The panel's own key monitor never sees that chord, because the tap
    /// swallows it before it reaches any window.
    func move(_ delta: Int) {
        guard isOpen else { return }
        model.move(delta)
    }

    func open() {
        prepare()
        guard let panel, !isOpen else { return }

        // An empty list still opens. The grid is a place you land and look around, so refusing to
        // appear is indistinguishable from the shortcut not working — and the empty state is the
        // only surface that can say whether the cause is a missing permission or an empty desk.
        let items = store.snapshot()
        previousApp = NSWorkspace.shared.frontmostApplication
        model.load(items)

        // The grid is the mode with the most room for a preview and was the only one never asking
        // for one, so window previews looked broken here while working everywhere else.
        if Preferences.shared.showsThumbnails {
            Task { @MainActor in
                ThumbnailProvider.shared.refresh(
                    for: items, targetSize: CGSize(width: 400, height: 250))
            }
        }

        // The whole screen, including under the menu bar — the backdrop dims everything or the
        // dimming reads as a large window rather than as a mode.
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
        panel.setFrame(frame, display: true)
        // Resize the hosting view with the panel explicitly. Autoresizing covers the common
        // case; a display change between prepare() and open() is the one it does not.
        if let content = panel.contentView {
            content.frame = NSRect(origin: .zero, size: frame.size)
            hosting?.frame = content.bounds
        }

        isOpen = true
        BackdropPanel.shared.show()
        NSApp.activate()
        // The cards pop; the dim just fades. Scaling the hosting view rather than the content
        // view is what separates them — the backdrop is the *window's* background colour, so it
        // is not inside anything being scaled and cannot grow with the cards.
        if let hosting {
            OverlayChrome.present(panel: panel, scaling: hosting, makeKey: true)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        installKeyMonitor()
    }

    func close(commit: Bool) {
        guard isOpen else { return }
        isOpen = false
        onClose()
        BackdropPanel.shared.hide()
        removeKeyMonitor()
        if let panel, let hosting {
            OverlayChrome.dismiss(panel: panel, scaling: hosting)
        } else {
            panel?.orderOut(nil)
        }

        if commit, let target = model.selectedItem {
            store.raise(target)
        } else {
            previousApp?.activate()
        }
        previousApp = nil
    }

    // MARK: - Keys

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let hasCommand = event.modifierFlags.contains(.command)

        switch Int64(event.keyCode) {
        case Shortcut.Key.escape:
            // Esc clears a query before it cancels, so a mistyped search does not throw away the
            // whole session — the same rule Square follows.
            if !model.query.isEmpty {
                model.query = ""
                return true
            }
            close(commit: false)
        case Shortcut.Key.returnKey:
            close(commit: true)
        case Shortcut.Key.rightArrow:
            model.move(1)
        case Shortcut.Key.leftArrow:
            model.move(-1)
        case Shortcut.Key.downArrow:
            model.move(model.columns)
        case Shortcut.Key.upArrow:
            model.move(-model.columns)
        case Shortcut.Key.tab:
            model.move(event.modifierFlags.contains(.shift) ? -1 : 1)
        // The grid owns the keyboard, so these are the plain ⌘ chords a Mac user already knows —
        // unlike Square, which holds ⌘ for the whole session and has to use a different modifier.
        case Shortcut.Key.w where hasCommand:
            actOnSelection(store.close)
        case Shortcut.Key.m where hasCommand:
            actOnSelection(store.minimize)
        case Shortcut.Key.h where hasCommand:
            actOnSelection(store.toggleHidden)
        case Shortcut.Key.q where hasCommand:
            actOnSelection(store.quit)
        default:
            return false
        }
        return true
    }

    /// Row actions leave the grid open — closing four windows should not mean opening it four
    /// times. The list is re-read after a beat, because AX acts asynchronously and re-reading
    /// immediately returns the window that is still in the middle of closing.
    private func actOnSelection(_ action: @escaping (WindowItem) -> Void) {
        guard let item = model.selectedItem else { return }
        act(on: item, action)
    }

    private func act(on item: WindowItem, _ action: @escaping (WindowItem) -> Void) {
        action(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isOpen else { return }
            self.store.rebuild()
            self.model.replaceSource(self.store.snapshot())
        }
    }
}

/// The grid's contents and selection. Selection is a flat index across every group, because
/// arrow keys move through what the eye sees as one field of cards, not through sections.
final class GridModel: ObservableObject {

    @Published private(set) var groups: [DisplayGrouping.Group] = []
    @Published private(set) var flat: [WindowItem] = []
    @Published var selected: Int = 0
    @Published private(set) var columns: Int = 4
    /// The unfiltered count, so the field can say "3 of 12".
    @Published private(set) var total = 0
    @Published private(set) var isSearchEnabled = false

    /// Typing narrows the grid, ranked by the same scorer the other two modes use — so "three
    /// letters find the window you meant" means one thing across the whole app.
    @Published var query: String = "" {
        didSet { rebuildGroups(preservingSelection: true) }
    }

    private var source: [WindowItem] = []
    /// Windows per app across the *unfiltered* list. Filtering must not change what "this app has
    /// 4 windows" means, or searching would make the indicator count the search results.
    private var counts: [pid_t: Int] = [:]

    var selectedItem: WindowItem? {
        flat.indices.contains(selected) ? flat[selected] : nil
    }

    func windowCount(for item: WindowItem) -> Int {
        item.isAppOnly ? 0 : (counts[item.pid] ?? 1)
    }

    /// The column count the layout solver actually chose, pushed back from the view.
    ///
    /// `columns` used to be decided here from the item count alone. It cannot be: the grid now
    /// sizes itself to the viewport, so how many cards sit side by side depends on the screen. A
    /// stale number here would make ↓ jump the wrong distance, which reads as the arrow keys
    /// being broken rather than as a layout detail.
    func setEffectiveColumns(_ count: Int) {
        let clamped = max(1, count)
        guard clamped != columns else { return }
        columns = clamped
    }

    func load(_ items: [WindowItem]) {
        source = items
        total = items.count
        counts = items.reduce(into: [:]) { result, item in
            guard !item.isAppOnly else { return }
            result[item.pid, default: 0] += 1
        }
        query = ""
        isSearchEnabled = Preferences.shared.isSearchEnabled
        rebuildGroups(preservingSelection: false)
    }

    /// Replace the underlying list after an action — a closed window, a quit app — without
    /// dropping the query or throwing the selection back to the top.
    func replaceSource(_ items: [WindowItem]) {
        source = items
        total = items.count
        counts = items.reduce(into: [:]) { result, item in
            guard !item.isAppOnly else { return }
            result[item.pid, default: 0] += 1
        }
        rebuildGroups(preservingSelection: true)
    }

    private func rebuildGroups(preservingSelection: Bool) {
        let filtered = FuzzyMatch.rank(source, query: query) {
            "\($0.appName) \($0.displayTitle)"
        }
        groups = DisplayGrouping.group(filtered)
        // The flat order must match the visual order, or arrow keys jump between displays in a
        // way that looks like a bug rather than a shortcut.
        flat = groups.flatMap(\.items)
        // `isCompact` and `columns` are no longer decided here — `GridLayout` solves for both
        // against the real viewport and pushes the answer back through `setEffectiveColumns`.
        // A count-based guess could not know how much screen there is, which is the whole
        // question when the grid must fit without scrolling.
        if preservingSelection {
            selected = flat.isEmpty ? 0 : min(selected, flat.count - 1)
        } else {
            // Index 1 is the previous window, as everywhere else — unless the user asked to land
            // on what is already in front.
            selected = flat.count > 1 && !Preferences.shared.opensOnActiveApp ? 1 : 0
        }
    }

    func move(_ delta: Int) {
        guard !flat.isEmpty else { return }
        selected = (selected + delta + flat.count) % flat.count
    }

    /// The flat index a group's item sits at, so the view can tag cards without recomputing.
    func flatIndex(of group: DisplayGrouping.Group, offset: Int) -> Int {
        var base = 0
        for candidate in groups {
            if candidate.id == group.id { break }
            base += candidate.items.count
        }
        return base + offset
    }
}
