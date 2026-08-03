import AppKit

/// The settings that outlive a launch.
///
/// Every one of these is read by something outside SwiftUI — the status item, the overlay panel,
/// the event tap — so it lives here rather than in `@AppStorage` scattered across views, and it
/// publishes changes so a setting can take effect live rather than on next launch.
/// `design-language.md` §11: a setting that needs a restart is a setting that will be assumed
/// broken.
final class Preferences: ObservableObject {

    static let shared = Preferences()

    /// Three is the cap because a switcher with four ways in has no primary way in. It is also
    /// what the user asked for, and a list that grows without limit needs a delete affordance,
    /// a reorder affordance and a conflict story that none of this earns.
    static let maxBindings = 3

    private enum Key {
        static let frosted = "hexad.frosted"
        static let hidesMenuBarIcon = "hexad.hidesMenuBarIcon"
        static let appearance = "hexad.appearance"
        static let mode = "hexad.mode"
        static let bindings = "hexad.bindings"
        static let swipe = "hexad.swipe"
        static let thumbnails = "hexad.thumbnails"
        static let hidesWindows = "hexad.hidesWindows"
        static let backdrop = "hexad.backdrop"
        static let search = "hexad.search"
        static let staysOpen = "hexad.staysOpen"
        static let thumbnailFit = "hexad.thumbnailFit"
        static let showsTitles = "hexad.showsTitles"
        static let launchAtLogin = "hexad.launchAtLogin"
        static let sortOrder = "hexad.sortOrder"
        static let excluded = "hexad.excludedApps"
        static let activeDisplay = "hexad.activeDisplayOnly"
        static let showsCount = "hexad.showsCount"
        static let opensOnActive = "hexad.opensOnActiveApp"
        static let remembersQuery = "hexad.remembersQuery"
        static let holdToPreview = "hexad.holdToPreview"
        static let scrollSteps = "hexad.scrollSteps"
        static let settingsShortcut = "hexad.settingsShortcut"
        static let pinned = "hexad.pinnedWindows"
        static let workspaces = "hexad.workspaces"
        static let perAppModes = "hexad.perAppModes"
        static let remembersSelection = "hexad.remembersSelection"
        static let wrapIndicator = "hexad.wrapIndicator"
        static let hintSessions = "hexad.hintSessions"
        static let refreshesPreview = "hexad.refreshesPreview"
        static let menuBarCount = "hexad.menuBarCount"
        static let hoverActions = "hexad.hoverActions"
        static let quickLook = "hexad.quickLook"
        static let separatesApps = "hexad.separatesApps"
    }

    /// System / Light / Dark. Pinning also pins `NSApp.appearance`, so a light pane never sits
    /// beside a dark one. §12.
    enum AppearancePin: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    // MARK: - Surface

    @Published var isFrosted: Bool {
        didSet { defaults.set(isFrosted, forKey: Key.frosted) }
    }

    @Published var hidesMenuBarIcon: Bool {
        didSet { defaults.set(hidesMenuBarIcon, forKey: Key.hidesMenuBarIcon) }
    }

    @Published var appearance: AppearancePin {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    /// Window previews instead of app icons. The **only** thing in hexad that needs Screen
    /// Recording.
    ///
    /// **On by default as of 0.6.1, reversing PLAN.md §2.** The original rule was that an app
    /// which asks for the screen on first launch, to do something the user never requested, is an
    /// app that gets denied — and that was right for the app as it then was. Two things changed:
    ///
    /// 1. **Onboarding now asks.** There is a step with a live switch, an explanation that it is
    ///    optional, and a "do it later" button. The permission is no longer sprung on anyone; it
    ///    is a question with a visible answer, which is the thing the old rule was protecting.
    /// 2. **Previews are what the switcher is for.** Run with them off, hexad is a nicer row of
    ///    app icons. Run with them on, it answers "which of these four documents" — and that is
    ///    the case ⌘Tab cannot handle and the reason to replace it.
    ///
    /// The claim in the README has to change with it: hexad needs **one** permission to work and
    /// asks for a second, once, for previews — rather than "one permission" full stop. Saying it
    /// the old way while shipping this default would be marketing rather than description.
    @Published var showsThumbnails: Bool {
        didSet { defaults.set(showsThumbnails, forKey: Key.thumbnails) }
    }

    /// What sits behind the switcher: nothing, or something that hides the windows you are
    /// choosing between. The grid always had this; the other modes could not have it at all.
    enum Backdrop: String, Codable, CaseIterable, Identifiable {
        case wallpaper, frosted, dim, solid
        var id: String { rawValue }

        var label: String {
            switch self {
            case .wallpaper: return "Wallpaper"
            case .frosted: return "Frosted"
            case .dim: return "Dim"
            case .solid: return "Solid"
            }
        }
    }

    /// Hide the open apps and windows while switching.
    @Published var hidesWindowsWhileSwitching: Bool {
        didSet { defaults.set(hidesWindowsWhileSwitching, forKey: Key.hidesWindows) }
    }

    @Published var backdrop: Backdrop {
        didSet { defaults.set(backdrop.rawValue, forKey: Key.backdrop) }
    }

    /// Type to filter while the switcher is open.
    ///
    /// Works even in Square, which never takes keyboard focus: the event tap already sees every
    /// keystroke while a session is open, so letters can filter the list without the panel ever
    /// becoming key — which it must not, or releasing the modifier stops being detectable.
    @Published var isSearchEnabled: Bool {
        didSet { defaults.set(isSearchEnabled, forKey: Key.search) }
    }

    /// How a window preview sits in a square tile.
    ///
    /// Only Square has to answer this. A window is landscape and its tile is square, so something
    /// has to give: Fill crops the sides and keeps the tile full, Fit shows the whole window and
    /// leaves bars above and below. Neither is right for everyone, which is why it is a setting
    /// rather than a decision. The list and grid size their previews to the window's own aspect
    /// and ignore this entirely.
    enum ThumbnailFit: String, CaseIterable, Identifiable {
        case fill, fit
        var id: String { rawValue }
        var label: String { self == .fill ? "Fill" : "Fit" }
    }

    @Published var thumbnailFit: ThumbnailFit {
        didSet { defaults.set(thumbnailFit.rawValue, forKey: Key.thumbnailFit) }
    }

    /// The window title under each tile. On by default — two windows of one app are otherwise
    /// indistinguishable — but a switcher of app icons alone is a legitimate thing to want, and
    /// with previews on the title is often already legible in the preview itself.
    @Published var showsTitles: Bool {
        didSet { defaults.set(showsTitles, forKey: Key.showsTitles) }
    }

    /// Register with macOS to start at login.
    ///
    /// The stored value is only ever a mirror of what `SMAppService` reports — the registration
    /// itself lives with macOS, and a preference that disagreed with it would be a switch that
    /// lies. `LoginItem` re-reads the service on launch.
    @Published var launchesAtLogin: Bool {
        didSet {
            defaults.set(launchesAtLogin, forKey: Key.launchAtLogin)
            LoginItem.setEnabled(launchesAtLogin)
        }
    }

    /// Stay open when the hotkey is released, instead of committing on release.
    @Published var staysOpen: Bool {
        didSet { defaults.set(staysOpen, forKey: Key.staysOpen) }
    }

    // MARK: - The list

    /// MRU, alphabetical, or grouped by app. See `WindowSort`.
    @Published var sortOrder: WindowSort {
        didSet { defaults.set(sortOrder.rawValue, forKey: Key.sortOrder) }
    }

    /// Bundle identifiers hexad will not list. Empty by default — an exclusion list that ships
    /// with entries is a switcher hiding things the user never asked it to hide.
    @Published var excludedBundleIDs: Set<String> {
        didSet {
            defaults.set(Array(excludedBundleIDs).sorted(), forKey: Key.excluded)
            NotificationCenter.default.post(name: .hexadWindowListChanged, object: nil)
        }
    }

    /// Show only the windows on the display the pointer is on. Off by default: a switcher that
    /// silently omits windows is worse than a long list, and on one display it does nothing.
    @Published var limitsToActiveDisplay: Bool {
        didSet {
            defaults.set(limitsToActiveDisplay, forKey: Key.activeDisplay)
            NotificationCenter.default.post(name: .hexadWindowListChanged, object: nil)
        }
    }

    /// "7 windows" in the overlay. On by default — it is the cheapest confidence the app can
    /// offer, because a list that is quietly missing something looks exactly like a complete one.
    @Published var showsCount: Bool {
        didSet { defaults.set(showsCount, forKey: Key.showsCount) }
    }

    /// Where the selection starts.
    ///
    /// Index 1 — the previous window — is what a single tap of ⌘Tab has meant on this platform
    /// for twenty years, so it stays the default. Starting on the *active* app was asked for
    /// during design and is the opposite of that convention, so it is offered rather than
    /// imposed: someone who uses the switcher to look rather than to bounce wants it.
    @Published var opensOnActiveApp: Bool {
        didSet { defaults.set(opensOnActiveApp, forKey: Key.opensOnActive) }
    }

    /// Keep a search query for a few seconds, so reopening after a mistype does not start blank.
    @Published var remembersQuery: Bool {
        didSet { defaults.set(remembersQuery, forKey: Key.remembersQuery) }
    }

    /// Raise whatever the selection rests on, without committing to it.
    ///
    /// Off by default, and deliberately so: it moves real windows around while someone is only
    /// looking, and an app that reorders the screen on a pause is startling until you know why
    /// it is happening.
    @Published var holdToPreview: Bool {
        didSet { defaults.set(holdToPreview, forKey: Key.holdToPreview) }
    }

    /// Two-finger scroll moves the selection while the switcher is open.
    @Published var scrollSteps: Bool {
        didSet { defaults.set(scrollSteps, forKey: Key.scrollSteps) }
    }

    // MARK: - Pins, workspaces, per-app modes

    /// Windows nailed to fixed slots. **N1** — see `PinnedWindows` for why position has to be able
    /// to hold still for ⌘1…⌘9 to be worth having.
    @Published var pinned: PinnedWindows {
        didSet {
            guard let data = try? JSONEncoder().encode(pinned) else { return }
            defaults.set(data, forKey: Key.pinned)
            NotificationCenter.default.post(name: .hexadWindowListChanged, object: nil)
        }
    }

    /// Named sets of windows, raised together. **N5.**
    @Published var workspaces: [Workspace] {
        didSet {
            guard let data = try? JSONEncoder().encode(workspaces) else { return }
            defaults.set(data, forKey: Key.workspaces)
        }
    }

    /// Bundle identifier to switcher mode. **N7.**
    ///
    /// Grid on the desktop and Square inside a full-screen editor is a real preference — the mode
    /// that suits "show me everything" is not the one that suits "flick back". Empty by default:
    /// one switcher is the design, and this is the exception someone opts into.
    @Published var perAppModes: [String: SwitcherMode] {
        didSet {
            let raw = perAppModes.mapValues(\.rawValue)
            defaults.set(raw, forKey: Key.perAppModes)
        }
    }

    /// The mode to use right now, honouring any override for the frontmost app.
    ///
    /// Read at the moment the switcher opens, never cached: the frontmost app is the whole input.
    var effectiveMode: SwitcherMode {
        guard !perAppModes.isEmpty,
              let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let override = perAppModes[bundleID]
        else { return mode }
        return override
    }

    // MARK: - Second-wave quality of life

    /// Return to the selection you were on, not only the query. **R1.**
    @Published var remembersSelection: Bool {
        didSet { defaults.set(remembersSelection, forKey: Key.remembersSelection) }
    }

    /// Mark the moment the cycle wraps past the end. **R2** — wrapping is silent, so a long hold
    /// looks like the list has stopped moving rather than gone round.
    @Published var showsWrapIndicator: Bool {
        didSet { defaults.set(showsWrapIndicator, forKey: Key.wrapIndicator) }
    }

    /// Re-capture the selected window's preview while you sit on it. **R5** — a capture can be
    /// minutes old, and a stale preview is a preview that lies.
    @Published var refreshesPreview: Bool {
        didSet { defaults.set(refreshesPreview, forKey: Key.refreshesPreview) }
    }

    /// The window count beside the menu bar glyph. **N9.**
    @Published var showsMenuBarCount: Bool {
        didSet {
            defaults.set(showsMenuBarCount, forKey: Key.menuBarCount)
            NotificationCenter.default.post(name: .hexadMenuBarChanged, object: nil)
        }
    }

    /// A close and a minimise button on the tile under the pointer. **N3** — ⌘W exists, and
    /// nobody discovers it.
    @Published var showsHoverActions: Bool {
        didSet { defaults.set(showsHoverActions, forKey: Key.hoverActions) }
    }

    /// Space bar opens a full-size preview of the selection. **N10.**
    @Published var quickLookEnabled: Bool {
        didSet { defaults.set(quickLookEnabled, forKey: Key.quickLook) }
    }

    /// Draw the windowless apps as their own row rather than trailing the windows. **N6.**
    @Published var separatesApps: Bool {
        didSet { defaults.set(separatesApps, forKey: Key.separatesApps) }
    }

    /// How many more launches should show the keyboard hint. **R4.**
    ///
    /// The footer hint was removed as chrome, correctly — a hint on every invocation is furniture.
    /// A hint on the first few is teaching. Counts down and stops.
    var remainingHintSessions: Int {
        get { defaults.object(forKey: Key.hintSessions) as? Int ?? 3 }
        set { defaults.set(max(0, newValue), forKey: Key.hintSessions) }
    }

    /// A chord that opens Settings from anywhere.
    ///
    /// This exists because the menu bar icon can be hidden, and hiding it made Settings
    /// unreachable without relaunching the app — a setting that disables the only route to
    /// settings. `nil` means unbound, which is allowed: the menu bar is enough for most people.
    @Published var settingsBinding: KeyBinding? {
        didSet {
            guard let settingsBinding, let data = try? JSONEncoder().encode(settingsBinding) else {
                defaults.removeObject(forKey: Key.settingsShortcut)
                return
            }
            defaults.set(data, forKey: Key.settingsShortcut)
        }
    }

    // MARK: - Input

    @Published var mode: SwitcherMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }

    @Published var bindings: [KeyBinding] {
        didSet { saveBindings() }
    }

    /// The three-finger swipe, on or off. It used to be a direction, which meant half of a
    /// naturally two-way gesture did nothing — swiping back the other way was simply ignored.
    @Published var isSwipeEnabled: Bool {
        didSet { defaults.set(isSwipeEnabled ? "on" : "off", forKey: Key.swipe) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        // **The shipped defaults are the configuration actually in use**, not a guess made before
        // the app had been lived with: frosted, the wallpaper backdrop with windows hidden while
        // switching, Square, previews off, search off. Taking them from a real working setup is the
        // same rule stow follows — a default nobody has run is a default nobody has tested.
        //
        // Search ships **on** again now that Square leads with a visible search tile. It was off
        // only because typing into a strip with no field on screen read as the switcher losing
        // keystrokes; with somewhere for the characters to appear, that objection is gone.
        // Read back from a running install on **2026-07-28, second pass**, after a fresh profile
        // had been lived in for a while, and adopted wholesale. Same rule stow follows: a default
        // nobody has run is a default nobody has tested.
        //
        // This pass reversed most of the first one. Nearly everything that was switched off by
        // the previous reading came back on once the features around it worked — the count, the
        // titles, the remembered query — which is the argument for reading the machine rather
        // than reasoning about it.
        defaults.register(defaults: [
            Key.frosted: true,
            Key.search: true,
            // The backdrop is back on, over the wallpaper. The earlier reading had it off
            // entirely; with previews on, covering the desktop turns out to help rather than
            // remove context — the previews *are* the context.
            Key.hidesWindows: true,
            Key.backdrop: Backdrop.wallpaper.rawValue,
            // Both on: with previews showing the window itself, the title names which one, and
            // the count says the list is complete.
            Key.showsTitles: true,
            Key.showsCount: true,
            Key.remembersQuery: true,
            // Still off. The swipe scrubs while the fingers are down, which covers the same
            // ground, and a switcher that moves under an idle two-finger rest is startling.
            Key.scrollSteps: false,
            Key.swipe: "on",
            // Land on the window you are already in rather than the previous one. The opposite of
            // every ⌘Tab on the platform, and what the app is actually run with — which is the
            // whole reason it is a setting.
            Key.opensOnActive: true,
            // **Stay open.** The switcher survives the key release and waits for a decision. This
            // turns hexad from a gesture into a mode, and it is the largest single behavioural
            // difference from stock ⌘Tab.
            Key.staysOpen: true,
            // **Window previews on, and with them the Screen Recording prompt.** This reverses the
            // one-permission-by-default posture of PLAN.md §2 — see the note below `showsThumbnails`
            // for why that is now defensible rather than a regression.
            Key.thumbnails: true,
            // Peek: pausing on a window raises it. Costs nothing until you pause, and answers
            // "is this the one I meant" better than any preview can.
            Key.holdToPreview: true,
            // Re-capture the selection while it is being looked at. Affordable now that it is
            // one window per pause rather than the whole list.
            Key.refreshesPreview: true,
            // The count beside the menu bar glyph.
            Key.menuBarCount: true,
            // The second-wave items that earn their place on by default: each answers a question
            // the switcher was silently failing to answer, rather than adding something new.
            Key.remembersSelection: true,
            Key.wrapIndicator: true,
            Key.hoverActions: true,
            Key.quickLook: true,
            Key.separatesApps: true,
        ])
        isFrosted = defaults.bool(forKey: Key.frosted)
        hidesMenuBarIcon = defaults.bool(forKey: Key.hidesMenuBarIcon)
        showsThumbnails = defaults.bool(forKey: Key.thumbnails)
        hidesWindowsWhileSwitching = defaults.bool(forKey: Key.hidesWindows)
        backdrop = Backdrop(rawValue: defaults.string(forKey: Key.backdrop) ?? "") ?? .wallpaper
        isSearchEnabled = defaults.bool(forKey: Key.search)
        staysOpen = defaults.bool(forKey: Key.staysOpen)
        showsTitles = defaults.bool(forKey: Key.showsTitles)
        launchesAtLogin = LoginItem.isEnabled
        showsCount = defaults.bool(forKey: Key.showsCount)
        opensOnActiveApp = defaults.bool(forKey: Key.opensOnActive)
        remembersQuery = defaults.bool(forKey: Key.remembersQuery)
        holdToPreview = defaults.bool(forKey: Key.holdToPreview)
        scrollSteps = defaults.bool(forKey: Key.scrollSteps)
        limitsToActiveDisplay = defaults.bool(forKey: Key.activeDisplay)
        sortOrder = WindowSort(rawValue: defaults.string(forKey: Key.sortOrder) ?? "") ?? .recent
        excludedBundleIDs = Set(defaults.stringArray(forKey: Key.excluded) ?? [])
        settingsBinding = defaults.data(forKey: Key.settingsShortcut)
            .flatMap { try? JSONDecoder().decode(KeyBinding.self, from: $0) }
        remembersSelection = defaults.bool(forKey: Key.remembersSelection)
        showsWrapIndicator = defaults.bool(forKey: Key.wrapIndicator)
        refreshesPreview = defaults.bool(forKey: Key.refreshesPreview)
        showsMenuBarCount = defaults.bool(forKey: Key.menuBarCount)
        showsHoverActions = defaults.bool(forKey: Key.hoverActions)
        quickLookEnabled = defaults.bool(forKey: Key.quickLook)
        separatesApps = defaults.bool(forKey: Key.separatesApps)
        pinned = defaults.data(forKey: Key.pinned)
            .flatMap { try? JSONDecoder().decode(PinnedWindows.self, from: $0) } ?? PinnedWindows()
        workspaces = defaults.data(forKey: Key.workspaces)
            .flatMap { try? JSONDecoder().decode([Workspace].self, from: $0) } ?? []
        perAppModes = (defaults.dictionary(forKey: Key.perAppModes) as? [String: String] ?? [:])
            .compactMapValues(SwitcherMode.init(rawValue:))
        thumbnailFit = ThumbnailFit(rawValue: defaults.string(forKey: Key.thumbnailFit) ?? "")
            ?? .fill
        appearance = AppearancePin(rawValue: defaults.string(forKey: Key.appearance) ?? "")
            ?? .system
        mode = SwitcherMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .square
        // Any stored direction from an older build counts as "on" — the choice is gone, not the
        // feature, and silently switching someone's gesture off would read as a regression.
        isSwipeEnabled = (defaults.string(forKey: Key.swipe).map { $0 != "off" }) ?? true

        // **Three bindings ship: ⌘Tab, ⌥Tab, ⌃Tab.** Read back from the running install, where all
        // three had been added by hand.
        //
        // For a while only ⌘Tab shipped, on the reasoning that answering a chord nobody chose is
        // presumptuous. In practice the other two earn their place for a reason that argument
        // missed: **⌘Tab does not work until the macOS switcher has been turned off**, so an app
        // that ships ⌘Tab alone does nothing at all for anyone who declines that step or has not
        // reached it yet. ⌥Tab is the working fallback, and ⌃Tab is free.
        //
        // All three are removable, and the cap is still three — see `maxBindings`.
        if let data = defaults.data(forKey: Key.bindings),
           let stored = try? JSONDecoder().decode([KeyBinding].self, from: data),
           !stored.isEmpty {
            bindings = Array(stored.prefix(Self.maxBindings))
        } else {
            bindings = [.commandTab, .optionTab, .controlTab]
        }
    }

    private func saveBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: Key.bindings)
    }

    // MARK: - Binding edits

    func setBinding(_ binding: KeyBinding, at index: Int) {
        var updated = bindings
        // A chord assigned twice would fire twice and read as a stuck key. Drop the old home.
        updated.removeAll { $0 == binding }
        if updated.indices.contains(index) {
            updated[index] = binding
        } else {
            updated.append(binding)
        }
        bindings = Array(updated.prefix(Self.maxBindings))
    }

    func removeBinding(at index: Int) {
        guard bindings.indices.contains(index) else { return }
        var updated = bindings
        updated.remove(at: index)
        // Never leave the app with no way in. Someone who clears the last binding has locked
        // themselves out of a switcher whose only UI is the switcher.
        bindings = updated.isEmpty ? [.commandTab] : updated
    }

    func addBinding(_ binding: KeyBinding) {
        guard bindings.count < Self.maxBindings, !bindings.contains(binding) else { return }
        bindings.append(binding)
    }

    /// The chord shown wherever one shortcut has to stand for hexad — the strip's own footer,
    /// the menu bar. The first that can actually fire right now, so the hint never names ⌘Tab
    /// while the macOS switcher still owns it.
    var primaryBinding: KeyBinding {
        let ownsCommandTab = SystemSwitcher.cachedState == .hexadOwnsCommandTab
        let usable = bindings.first { binding in
            ownsCommandTab || !binding.flags.contains(.maskCommand)
                || binding.keyCode != Shortcut.Key.tab
        }
        return usable ?? bindings.first ?? .optionTab
    }

    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }
}
