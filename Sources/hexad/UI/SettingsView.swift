import SwiftUI

/// Settings: a window with left-sidebar nav, grouped sections, one-line grey descriptions.
/// Panes run in the order someone meets them — General first, About last.
/// `design-language.md` §11.
struct SettingsView: View {

    /// Five panes, each answering one whole question.
    ///
    /// There were six, and the sixth — General — held two switches that belonged with the rest of
    /// "how the app itself runs", in Setup. More importantly the panes overlapped: previews were
    /// in Switcher while the permission they need was in Setup, and the tile's appearance was
    /// split between Switcher and Appearance. Changing one thing meant visiting two panes and
    /// following a written instruction to get to the second. Now each pane is self-sufficient —
    /// every control that needs a permission or a related setting has it in the same row group.
    enum Pane: String, CaseIterable, Identifiable {
        // Setup first because nothing else matters until it is done; About last. Between them:
        // what the switcher is and lists, how it opens, how it looks.
        case setup, switcher, shortcuts, appearance, about
        var id: String { rawValue }

        var label: String {
            switch self {
            case .setup: return "Setup"
            case .switcher: return "Switcher"
            case .shortcuts: return "Shortcuts"
            case .appearance: return "Appearance"
            case .about: return "About"
            }
        }

        var systemImage: String {
            switch self {
            case .setup: return "checklist"
            case .switcher: return "square.on.square"
            case .shortcuts: return "keyboard"
            case .appearance: return "paintbrush"
            case .about: return "info.circle"
            }
        }
    }

    @StateObject private var model = SettingsModel()
    @StateObject private var preferences = Preferences.shared
    @State private var pane: Pane = .setup

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color(nsColor: Palette.NS.border))
                .frame(width: 1)
            content
        }
        .onAppear { model.refresh() }
        // Accessibility is granted in another app, so nothing here fires when it changes. A
        // settings window that says "not granted" while System Settings says otherwise is worse
        // than no status at all — it makes the user doubt the grant, not the window.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.refresh()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            // The traffic lights float over this surface, so the header clears them. §3.
            HStack(spacing: Theme.Space.s8) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 20, height: 20)
                }
                Text("hexad")
                    .font(Font(Theme.Font.headline))
                    .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))
            }
            .padding(.top, 30)
            .padding(.bottom, Theme.Space.s12)
            .padding(.horizontal, Theme.Space.s12)

            ForEach(Pane.allCases) { item in
                sidebarRow(item)
            }

            Spacer()
        }
        .padding(.horizontal, Theme.Space.s8)
        .padding(.bottom, Theme.Space.s16)
        .frame(width: 168, alignment: .leading)
    }

    private func sidebarRow(_ item: Pane) -> some View {
        let isSelected = pane == item
        return Button { pane = item } label: {
            HStack(spacing: Theme.Space.s8) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .frame(width: Theme.Control.listIcon)
                Text(item.label)
                    .font(Font(isSelected ? Theme.Font.bodyEmph : Theme.Font.body))
                Spacer(minLength: 0)
            }
            // Selected is a wash with an accent glyph and a heavier title — never a full
            // accent fill, which §10 reserves for actions rather than for saying where you are.
            .foregroundStyle(Color(nsColor: isSelected
                                   ? Palette.NS.accent
                                   : Palette.NS.textSecondary))
            .padding(.vertical, Theme.Space.s8)
            .padding(.horizontal, Theme.Space.s8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color(nsColor: isSelected ? Palette.NS.accentSoft : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.betweenSections) {
                switch pane {
                case .setup:
                    SetupPane(model: model, preferences: preferences)
                case .switcher:
                    SwitcherPane(model: model, preferences: preferences)
                case .shortcuts:
                    ShortcutsPane(model: model,
                                  preferences: preferences,
                                  trackpad: TrackpadGesture.shared)
                case .appearance:
                    AppearancePane(preferences: preferences, model: model)
                case .about:
                    AboutPane(version: model.version)
                }
            }
            .padding(.top, 30)
            .padding(.horizontal, Theme.Space.panelPadding)
            .padding(.bottom, Theme.Space.panelPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        // Chrome frosts; content does not. §3. The sidebar lets the desktop through and this
        // pane paints over the same window-level blur, because dense text has to stay readable
        // over any wallpaper. Painting is how a pane opts out — never a second effect view.
        .background(Color(nsColor: Palette.NS.bg))
    }
}

/// Reads live system state rather than storing its own copy, so the window can never disagree
/// with the machine. Refreshed on appear and once a second while open.
final class SettingsModel: ObservableObject {

    /// How long a swipe stays "just seen". Long enough to look away from the trackpad and back
    /// at the window, short enough that a stale yes is not mistaken for a live one.
    private static let swipeFreshness: TimeInterval = 6

    @Published var switcherStatus = ""
    @Published var listeningSummary = ""
    @Published var shortcutLabel = ""
    @Published var isAccessibilityGranted = false
    @Published var isScreenRecordingGranted = false
    @Published var isListening = false
    /// Published, not read live in a view body: `SystemSwitcher.state` is a function
    /// call, so SwiftUI has nothing to invalidate on and the pane kept showing whatever
    /// the state was when it was first drawn.
    @Published var switcherState: SystemSwitcher.State = .unsupported
    @Published var hasSeenSwipe = false
    @Published var lastSwipeSummary = "None yet"

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    init() { refresh() }

    func refresh() {
        // The hot path reads a cache; a settings window that showed the cache could be five
        // seconds stale while claiming to be the source of truth.
        SystemSwitcher.refreshCachedState()
        switcherState = SystemSwitcher.state
        switcherStatus = SystemSwitcher.statusDescription
        isAccessibilityGranted = Permissions.isAccessibilityGranted
        isScreenRecordingGranted = Permissions.isScreenRecordingGranted
        isListening = RuntimeStatus.shared.isListening
        listeningSummary = RuntimeStatus.shared.summary
        shortcutLabel = Preferences.shared.primaryBinding.label
        refreshSwipe()
    }

    private func refreshSwipe() {
        let gesture = TrackpadGesture.shared
        guard let seen = gesture.lastSeen, let at = gesture.lastSeenAt else {
            hasSeenSwipe = false
            lastSwipeSummary = "None yet"
            return
        }
        let age = Date().timeIntervalSince(at)
        hasSeenSwipe = age < Self.swipeFreshness
        lastSwipeSummary = hasSeenSwipe
            ? "Seen \(seen == .right ? "→" : "←")"
            : "Last: \(seen == .right ? "→" : "←"), \(Int(age))s ago"
    }

    func disableSystemSwitcher() {
        SystemSwitcher.disable()
        refresh()
    }

    func restoreSystemSwitcher() {
        SystemSwitcher.restore()
        refresh()
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
        refresh()
    }
}
