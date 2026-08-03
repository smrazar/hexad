import AppKit

/// The state machine between "hotkey pressed" and "window raised".
///
/// A session begins when a binding fires and ends when its modifier comes up. Everything in
/// between — cycling, cancelling — is index arithmetic on a snapshot taken at the start. Taking
/// the snapshot once is deliberate: a list that reorders itself under the user's fingers while
/// they are tabbing through it is the single most disorienting thing a switcher can do.
final class SwitcherSession {

    private let store: WindowStore
    private let overlay: StripOverlay
    /// Opening the palette or the grid is not this object's job — it recognises the binding and
    /// hands off, because those two own the keyboard and this state machine deliberately never
    /// does. `delta` is 0 to open, ±1 to move the selection of one that is already open.
    ///
    /// The distinction is the fix for a real bug: the binding used to open-or-*toggle*, so a
    /// second ⌘Tab closed the switcher instead of advancing it, which is the opposite of what
    /// every ⌘Tab on this platform does.
    var onSecondaryBinding: (_ delta: Int) -> Void = { _ in }
    /// Whether the palette or grid is on screen right now. Only they know.
    var isSecondaryOpen: () -> Bool = { false }
    /// Release-to-commit for the palette and grid, when a held binding opened them.
    var onSecondaryCommit: () -> Void = {}

    private var items: [WindowItem] = []
    /// The unfiltered snapshot. Typing narrows `items`; backspacing has to widen it again, which
    /// needs the original to still exist.
    private var allItems: [WindowItem] = []
    private var query = ""
    private var index = 0
    private var binding: KeyBinding = .optionTab
    /// A binding with no modifier — F13 on its own — has nothing to release, so the strip cannot
    /// end when the user lets go. It stays up and commits on Return instead. Waiting for a key-up
    /// that cannot arrive would leave the overlay on screen forever.
    private var isSticky = false
    private(set) var isActive = false

    /// Set when a *held* binding opened the palette or grid and the user has not asked them to
    /// stay open. Releasing that modifier then commits, exactly as the strip does — which is what
    /// makes "Stay open" mean something in the two modes that used to ignore it entirely.
    private var secondaryHold: KeyBinding?

    /// The search tile is **not** a slot in the cycle. Typing filters whatever is open, from the
    /// first keystroke, so landing on the tile first bought nothing and gave the cycle a position
    /// with nothing to switch to. It stays on screen as the place the query appears.
    private var isOnSearch = false

    /// How long a query survives the session that typed it. Long enough to reopen after a
    /// mistype, short enough that the switcher is never mysteriously pre-filtered.
    private static let queryMemory: TimeInterval = 5

    /// How long the selection must rest before "hold to preview" raises it. Under a third of a
    /// second and it fires while someone is still tabbing through; much over half a second and it
    /// never fires at all during a normal cycle.
    private static let previewDwell: TimeInterval = 0.4

    /// Scroll distance per selection step. Trackpad scrolling arrives in small continuous
    /// deltas, so they accumulate rather than each one counting as a step.
    private static let scrollPerStep: CGFloat = 14

    private var lastQuery = ""
    private var lastQueryAt: Date = .distantPast
    /// **R1.** The identity the last session ended on, so reopening within a few seconds returns
    /// to where you were looking rather than to index 1. Stored as an identity, not an index: the
    /// list reorders between sessions, and an index would point at whatever moved into the slot.
    private var lastSelection: String?

    /// **N4.** Set when the list has been narrowed to one app. Kept so ← can widen it again and
    /// the header can say what is being looked at.
    private var appFilter: String?

    /// **R7.** Two Escapes inside this window quit the app. Short enough that it cannot be reached
    /// by cancelling twice in the course of normal use.
    private static let doubleEscapeWindow: TimeInterval = 0.6
    private var lastEscape: Date = .distantPast

    /// The window that was in front when the session opened, so a preview can be undone.
    private var previewReturn: WindowItem?
    private var previewTimer: Timer?
    private var previewedIdentity: String?

    private var scrollMonitors: [Any] = []
    private var scrollAccumulator: CGFloat = 0

    /// The unfiltered count, kept so the overlay can say "3 of 12" rather than only "3".
    private var totalCount = 0

    init(store: WindowStore, overlay: StripOverlay) {
        self.store = store
        self.overlay = overlay
    }

    // MARK: - The tap's decision

    /// Called straight from the event tap. Must stay arithmetic — see HotkeyTap's 1ms budget.
    /// Anything that draws is pushed to the next main-loop turn.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .keyDown:
            return handleKeyDown(keyCode: keyCode, flags: flags)

        case .keyUp:
            // A stray Tab keyUp reaching the focused app inserts a tab character into whatever
            // had focus. Swallow the other half of anything we swallowed going down.
            if isActive, keyCode == binding.keyCode { return true }
            return secondaryHold.map { $0.keyCode == keyCode } ?? false

        case .flagsChanged:
            // Releasing the modifier is what commits. The event itself always passes through —
            // swallowing a modifier change leaves other apps believing a key is still held.
            if isActive, !isSticky, !binding.isHeld(in: flags) {
                commit()
            }
            if let hold = secondaryHold, !hold.isHeld(in: flags) {
                secondaryHold = nil
                let commit = onSecondaryCommit
                DispatchQueue.main.async { commit() }
            }
            return false

        default:
            return false
        }
    }

    private func handleKeyDown(keyCode: Int64, flags: CGEventFlags) -> Bool {
        // Settings first, and from anywhere. The menu bar icon can be hidden, and hiding it used
        // to make Settings unreachable without relaunching the app — a setting that switched off
        // the only route back to settings.
        if let settings = Preferences.shared.settingsBinding,
           settings.matches(keyCode: keyCode, flags: flags) {
            if isActive { cancel() }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .hexadOpenSettings, object: nil)
            }
            return true
        }

        if isActive {
            return handleKeyWhileOpen(keyCode: keyCode, flags: flags)
        }

        // ⌘` while the palette or grid is up: step back, without needing the binding to match.
        if keyCode == Shortcut.Key.grave, isSecondaryOpen(),
           Preferences.shared.bindings.contains(where: { $0.isHeld(in: flags) }) {
            let hand = onSecondaryBinding
            DispatchQueue.main.async { hand(-1) }
            return true
        }

        guard let match = Preferences.shared.bindings.first(where: {
            $0.matches(keyCode: keyCode, flags: flags)
        }) else { return false }

        // One mode answers the bindings. The other two are not listening, which is the whole
        // point of SwitcherMode — see that file. `effectiveMode` honours a per-app override
        // (**N7**), read now rather than cached because the frontmost app is the entire input.
        switch Preferences.shared.effectiveMode {
        case .square:
            begin(with: match, backwards: flags.contains(.maskShift))

        case .list, .grid:
            // Already open: this press moves the selection. Shift reverses, as everywhere else.
            // Closed: open it, and remember the chord if it is one that can be released, so the
            // release can commit.
            let isOpen = isSecondaryOpen()
            let delta = isOpen ? (flags.contains(.maskShift) ? -1 : 1) : 0
            if !isOpen {
                secondaryHold = (match.isHoldable && !Preferences.shared.staysOpen) ? match : nil
            }
            let hand = onSecondaryBinding
            DispatchQueue.main.async { hand(delta) }
        }
        return true
    }

    /// The palette or grid closed by its own means — Esc, a click, Return. Whatever the modifier
    /// does now must not commit a switcher that is no longer on screen.
    func secondaryDidClose() {
        secondaryHold = nil
    }

    private func handleKeyWhileOpen(keyCode: Int64, flags: CGEventFlags) -> Bool {
        if binding.matches(keyCode: keyCode, flags: flags) {
            step(flags.contains(.maskShift) ? -1 : 1)
            return true
        }

        // ⌘` — the key above Tab, under the same modifier — steps backwards. ⇧⌘Tab still does
        // too; this is the second way, and the one that does not need a third finger.
        if keyCode == Shortcut.Key.grave, binding.isHeld(in: flags) {
            step(-1)
            return true
        }

        switch keyCode {
        case Shortcut.Key.escape:
            // Esc unwinds one layer at a time — query, then app filter, then the session — so a
            // mistyped search does not throw away everything. **R7:** twice in quick succession
            // on an *already empty* switcher quits hexad, which is the only keyboard route out of
            // an overlay that has wedged. Deliberately awkward to reach by accident.
            if !query.isEmpty {
                query = ""
                applyFilter()
                return true
            }
            if appFilter != nil {
                clearAppFilter()
                return true
            }
            if Date().timeIntervalSince(lastEscape) < Self.doubleEscapeWindow {
                RuntimeStatus.shared.trace("double Esc — quitting")
                end(undoingPreview: true)
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return true
            }
            lastEscape = Date()
            cancel()
            return true

        case Shortcut.Key.delete where !query.isEmpty:
            query.removeLast()
            applyFilter()
            return true
        case Shortcut.Key.rightArrow:
            step(1)
            return true
        case Shortcut.Key.leftArrow:
            // **N4.** ← backs out of an app filter before it moves the selection, so the pair of
            // arrows reads as "into this app" and "back out again".
            if appFilter != nil {
                clearAppFilter()
                return true
            }
            step(-1)
            return true
        case Shortcut.Key.downArrow:
            // **N4.** ↓ narrows to the selected window's app — "show me only this app's windows",
            // which is the question a row of six Vivaldi tiles provokes.
            if let target = currentItem, appFilter == nil, !target.isAppOnly {
                applyAppFilter(target.appName)
                return true
            }
            step(1)
            return true
        case Shortcut.Key.upArrow:
            if appFilter != nil {
                clearAppFilter()
                return true
            }
            step(-1)
            return true

        case Shortcut.Key.space where Preferences.shared.quickLookEnabled:
            // **N10.** Space is Finder's gesture for "show me this properly", and a switcher tile
            // is exactly the case where a thumbnail is too small to decide by.
            if let target = currentItem {
                let item = target
                DispatchQueue.main.async { QuickLookPanel.shared.toggle(for: item) }
            }
            return true
        case Shortcut.Key.returnKey where isSticky:
            commit()
            return true


        default:
            let extra = flags.subtracting(binding.flags)

            // An action rather than a keystroke: close, minimise, hide, quit. These need a
            // modifier the binding does not already hold — see `KeyBinding.actionModifier` for
            // why ⌘W cannot be the close key while ⌘Tab is what is being held down.
            if extra.contains(binding.actionModifier), let target = currentItem {
                return performAction(keyCode: keyCode, on: target)
            }

            // ⌘1…⌘9 — the position, not an offset. Muscle memory from every browser and terminal,
            // and the only way to reach the ninth window without nine keypresses. Checked before
            // the typing fallback, so a digit jumps rather than filtering.
            if let digit = KeyName.digit(keyCode), (1...9).contains(digit),
               items.indices.contains(digit - 1) {
                index = digit - 1
                pushSelection()
                commit()
                return true
            }

            // With search off, a bare letter jumps to the next app starting with it — rcmd's best
            // idea, and free now that the list is already in hand. With search *on* the same
            // keystroke means "filter", so this is the alternative to that rather than a second
            // meaning for it: one keyboard, one answer per key.
            if !Preferences.shared.isSearchEnabled, extra.isEmpty,
               let character = KeyName.typedCharacter(keyCode),
               jumpToApp(startingWith: character) {
                return true
            }

            // Typing filters, when the user has asked for that. The panel never takes focus —
            // it must not, or releasing the modifier stops being detectable — so the characters
            // arrive here through the tap instead, which is the only reason this can work at all
            // in a mode built around a held key.
            //
            // **The binding's own modifiers are subtracted before deciding whether this is a
            // shortcut rather than a keystroke.** Testing the raw flags meant that while ⌘Tab was
            // held — which is the entire duration of a Square session — every letter looked like a
            // ⌘-shortcut and was rejected. Search could not work in the one mode it was designed
            // for. Only a modifier the user has added *on top of* the binding disqualifies a key.
            guard Preferences.shared.isSearchEnabled,
                  !extra.contains(.maskCommand), !extra.contains(.maskControl),
                  let character = KeyName.typedCharacter(keyCode)
            else { return false }
            query.append(character)
            RuntimeStatus.shared.trace("typed '\(character)' · query '\(query)'")
            applyFilter()
            return true
        }
    }

    /// What the selection is resting on right now.
    private var currentItem: WindowItem? {
        guard !isOnSearch, items.indices.contains(index) else { return nil }
        return items[index]
    }

    // MARK: - Acting on the selection

    /// Close, minimise, hide or quit whatever is selected, without leaving the switcher.
    ///
    /// Staying open is the point: closing four windows should be four keystrokes, not four
    /// sessions. The list is rebuilt after each one so the next keystroke acts on what is
    /// actually there — acting on a stale snapshot would close the wrong window.
    private func performAction(keyCode: Int64, on target: WindowItem) -> Bool {
        switch keyCode {
        case Shortcut.Key.w:
            store.close(target)
        case Shortcut.Key.m:
            store.minimize(target)
        case Shortcut.Key.h:
            store.toggleHidden(target)
        case Shortcut.Key.q:
            store.quit(target)
        case Shortcut.Key.p:
            // **N1.** Pin or unpin the selection. The list is rebuilt so the tile moves to its
            // slot immediately — a pin that only takes effect next time reads as having failed.
            Preferences.shared.pinned = Preferences.shared.pinned.toggling(target.identity)
            RuntimeStatus.shared.trace("pin toggled on \(target.displayTitle)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.refreshWhileOpen()
            }
            return true
        default:
            return false
        }
        RuntimeStatus.shared.trace("action \(KeyName.of(keyCode)) on \(target.displayTitle)")
        // AX acts asynchronously — a window asked to close is not gone by the time this returns —
        // so the rebuild waits a beat rather than re-reading the same list it just changed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshWhileOpen()
        }
        return true
    }

    /// Rebuild the list under an open switcher, keeping the selection somewhere sensible.
    private func refreshWhileOpen() {
        guard isActive else { return }
        store.rebuild()
        allItems = store.snapshot()
        totalCount = allItems.count
        applyFilter()
    }

    // MARK: - Filtering to one app

    /// **N4.** Narrow to a single app's windows.
    ///
    /// Different from typing its name, which merely *ranks* its windows first and leaves every
    /// other window in the cycle. Six Vivaldi windows and forty others is exactly the case where
    /// ranking is not enough — the cycle still has to walk past everything else.
    private func applyAppFilter(_ appName: String) {
        appFilter = appName
        RuntimeStatus.shared.trace("filter to app '\(appName)'")
        applyFilter()
    }

    private func clearAppFilter() {
        guard appFilter != nil else { return }
        appFilter = nil
        RuntimeStatus.shared.trace("app filter cleared")
        applyFilter()
    }

    /// Jump to the next item whose app starts with this letter, wrapping — so pressing it again
    /// walks through that app's windows rather than sticking on the first.
    private func jumpToApp(startingWith character: Character) -> Bool {
        guard !items.isEmpty else { return false }
        let target = String(character).lowercased()
        let order = (1...items.count).map { (index + $0) % items.count }
        guard let found = order.first(where: {
            items[$0].appName.lowercased().hasPrefix(target)
        }) else { return false }

        index = found
        RuntimeStatus.shared.trace("letter '\(character)' → \(items[found].appName)")
        pushSelection()
        return true
    }

    // MARK: - Hold to preview

    /// Raise the selection after a pause, without committing to it.
    ///
    /// Off by default. It moves real windows while someone is only looking, which is startling
    /// until you know why it is happening — but it is also the only way to answer "is this the
    /// one I meant" for a window whose title and preview both look like three others.
    private func schedulePreview() {
        cancelPreviewTimer()

        // **R5.** A capture can be minutes old, and a stale preview is a preview that lies. While
        // the selection rests on a window, re-capture just that one — the whole list would be a
        // ScreenCaptureKit pass per pause, and only the one being looked at matters.
        if Preferences.shared.refreshesPreview, Preferences.shared.showsThumbnails,
           let target = currentItem, !target.isAppOnly {
            let item = target
            Task { @MainActor in
                ThumbnailProvider.shared.refresh(for: [item],
                                                 targetSize: CGSize(width: 480, height: 300),
                                                 force: true)
            }
        }

        guard Preferences.shared.holdToPreview, let target = currentItem,
              target.identity != previewedIdentity
        else { return }

        previewTimer = Timer.scheduledTimer(withTimeInterval: Self.previewDwell,
                                            repeats: false) { [weak self] _ in
            guard let self, self.isActive, let current = self.currentItem else { return }
            self.previewedIdentity = current.identity
            RuntimeStatus.shared.trace("preview \(current.displayTitle)")
            self.store.raise(current, remember: false)
        }
    }

    private func cancelPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    /// Put back whatever was in front before a preview moved it. Only when a preview actually
    /// happened — otherwise cancelling a switcher would raise a window nobody asked for.
    private func undoPreview() {
        cancelPreviewTimer()
        guard previewedIdentity != nil, let original = previewReturn else { return }
        previewedIdentity = nil
        store.raise(original, remember: false)
    }

    // MARK: - Scrolling

    /// Two fingers on the trackpad move the selection while the switcher is open.
    ///
    /// The swipe already opens it and scrubs while the fingers stay down; scrolling is the reach
    /// someone makes *after* that, and it did nothing at all. Both monitors are installed because
    /// a global one never sees events delivered to hexad's own panel and a local one never sees
    /// the ones delivered elsewhere — a switcher must answer the scroll wherever the pointer is.
    private func startScrollWatch() {
        stopScrollWatch()
        guard Preferences.shared.scrollSteps else { return }
        scrollAccumulator = 0

        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel,
                                                          handler: { [weak self] event in
            self?.handleScroll(event)
        }) {
            scrollMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel,
                                                        handler: { [weak self] event in
            self?.handleScroll(event)
            return event
        }) {
            scrollMonitors.append(local)
        }
    }

    private func stopScrollWatch() {
        scrollMonitors.forEach(NSEvent.removeMonitor)
        scrollMonitors.removeAll()
    }

    private func handleScroll(_ event: NSEvent) {
        guard isActive else { return }
        // Whichever axis moved further. A strip is horizontal and a list is vertical, and someone
        // scrolling "along" either of them means the same thing.
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : -event.scrollingDeltaY
        scrollAccumulator += delta
        let steps = Int(scrollAccumulator / Self.scrollPerStep)
        guard steps != 0 else { return }
        scrollAccumulator -= CGFloat(steps) * Self.scrollPerStep
        step(steps > 0 ? 1 : -1)
    }

    /// Narrow the list to what matches, keeping the same ranking the list mode uses so the two
    /// modes cannot disagree about what "three letters find the window you meant" means.
    private func applyFilter() {
        // The app filter is a hard narrowing and runs first; the query then ranks within it.
        let pool = appFilter.map { name in
            allItems.filter { $0.appName == name }
        } ?? allItems

        items = query.isEmpty
            ? pool
            : FuzzyMatch.rank(pool, query: query) { "\($0.appName) \($0.displayTitle)" }
        index = items.isEmpty ? 0 : min(index, items.count - 1)

        let shown = items
        let selected = index
        let label = binding.label
        let text = query
        let total = totalCount
        let reason = emptyReason
        let scope = appFilter
        DispatchQueue.main.async { [overlay] in
            overlay.show(items: shown, selected: selected, shortcutLabel: label, query: text,
                         total: total, emptyReason: reason, appFilter: scope)
        }
        schedulePreview()
    }

    /// Why the panel is empty — three different problems that used to show one blank tile.
    ///
    /// "No windows" and "Accessibility not granted" are not the same failure and do not have the
    /// same fix, and a user who sees the first when the truth is the second concludes the app is
    /// broken rather than un-permitted.
    private var emptyReason: OverlayEmptyReason {
        if !Permissions.isAccessibilityGranted { return .noAccessibility }
        if allItems.isEmpty { return .noWindows }
        return .noMatch
    }

    // MARK: - The mouse

    /// Hovering moves the selection without committing, exactly as arrowing does.
    func hover(index: Int) {
        guard isActive, items.indices.contains(index), index != self.index else { return }
        self.index = index
        overlay.select(index)
    }

    /// The trackpad moved while its fingers were still down.
    func stepFromGesture(_ delta: Int) {
        guard isActive else { return }
        step(delta)
    }

    /// The trackpad's fingers lifted: take the selection.
    func commitFromGesture() {
        guard isActive else { return }
        commit()
    }

    /// Clicking commits there and then, whatever the modifier is doing.
    func choose(index: Int) {
        guard isActive, items.indices.contains(index) else { return }
        self.index = index
        commit()
    }

    /// Middle-click closes that window and leaves the switcher up — what middle-click means
    /// everywhere tabs exist.
    func closeWindow(at index: Int) {
        guard isActive, items.indices.contains(index) else { return }
        let target = items[index]
        RuntimeStatus.shared.trace("close \(target.displayTitle)")
        store.close(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshWhileOpen()
        }
    }

    /// The minimise button on a hovered tile. **N3.**
    func minimizeWindow(at index: Int) {
        guard isActive, items.indices.contains(index) else { return }
        let target = items[index]
        RuntimeStatus.shared.trace("minimise \(target.displayTitle)")
        store.minimize(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refreshWhileOpen()
        }
    }

    // MARK: - Opening without a key

    /// Opens the strip for something that has nothing to hold — the trackpad swipe.
    ///
    /// A swipe is over the instant it happens, so the "release to commit" contract cannot apply.
    /// The strip stays up and waits for Return, an arrow, or Esc, exactly as a modifier-less
    /// binding does. Swiping again while it is open commits, so the gesture is its own toggle.
    func openSticky() {
        guard !isActive else {
            commit()
            return
        }
        begin(with: Preferences.shared.primaryBinding, backwards: false, sticky: true)
    }

    // MARK: - Transitions

    /// Watches for a click anywhere outside hexad while a sticky session is up.
    ///
    /// A held session ends when the modifier is released, so it never needed this. One that stays
    /// open has no such end, and a panel that ignores every click while it covers the screen is
    /// indistinguishable from a hang.
    private var clickAwayMonitor: Any?

    private func startClickAwayWatch() {
        stopClickAwayWatch()
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.isActive else { return }
            RuntimeStatus.shared.trace("dismissed by a click outside")
            self.cancel()
        }
    }

    private func stopClickAwayWatch() {
        if let clickAwayMonitor { NSEvent.removeMonitor(clickAwayMonitor) }
        clickAwayMonitor = nil
    }

    private func begin(with binding: KeyBinding, backwards: Bool, sticky: Bool = false) {
        let snapshot = store.snapshot()
        let willStick = sticky || !binding.isHoldable || Preferences.shared.staysOpen
        // An empty list still opens when there is nothing to release — the panel is then the only
        // place that can say *why* it is empty. A held ⌘Tab with nothing to switch to stays
        // silent, because a panel that appears and vanishes on the same keypress is just a flash.
        guard !snapshot.isEmpty || willStick else { return }

        self.binding = binding
        allItems = snapshot
        totalCount = snapshot.count
        // "Stay open" turns the whole thing from a gesture into a mode: the switcher survives
        // the release and waits for a decision, which is what someone who wants to look before
        // choosing is asking for.
        isSticky = willStick
        // A query survives for a few seconds, so reopening after a mistype does not start from a
        // blank field. Longer than that and the switcher would open mysteriously pre-filtered.
        query = restoredQuery()
        items = snapshot
        // Index 1 is "the last window I was in", which is what a single tap of ⌘Tab has meant on
        // this platform for twenty years. Index 0 is the window already in front, which is what
        // someone using the switcher to *look* rather than to bounce wants — hence the setting.
        let opensOnActive = Preferences.shared.opensOnActiveApp
        index = snapshot.count <= 1
            ? 0
            : (backwards ? snapshot.count - 1 : (opensOnActive ? 0 : 1))

        // **R1.** Return to what was being looked at, if this is a continuation rather than a new
        // decision. Matched by identity, because the list reorders between sessions and an index
        // would point at whatever moved into that slot.
        if !backwards,
           Preferences.shared.remembersSelection,
           Date().timeIntervalSince(lastQueryAt) < Self.queryMemory,
           let remembered = lastSelection,
           let restored = snapshot.firstIndex(where: { $0.identity == remembered }) {
            index = restored
        }
        isOnSearch = false
        isActive = true
        previewReturn = snapshot.first
        previewedIdentity = nil
        if isSticky { startClickAwayWatch() }
        startScrollWatch()
        RuntimeStatus.shared.trace("open \(binding.label) · \(snapshot.count) items"
            + " · index \(index) · sticky \(isSticky)")

        // Restoring a query means opening filtered, so the filter has to run rather than the
        // full list being shown under a query that no longer describes it.
        guard query.isEmpty else {
            applyFilter()
            return
        }

        let shown = items
        let selected = index
        let label = binding.label
        let total = totalCount
        let reason = emptyReason
        DispatchQueue.main.async { [overlay] in
            overlay.show(items: shown, selected: selected, shortcutLabel: label, query: "",
                         total: total, emptyReason: reason)
        }
        schedulePreview()
    }

    /// The query from the last session, if it is recent enough to still be what the user meant.
    private func restoredQuery() -> String {
        guard Preferences.shared.isSearchEnabled,
              Preferences.shared.remembersQuery,
              !lastQuery.isEmpty,
              Date().timeIntervalSince(lastQueryAt) < Self.queryMemory
        else { return "" }
        return lastQuery
    }

    /// Move one slot. With search on, slot 0 is the search tile and the windows follow it, so the
    /// arithmetic runs in slot space and is mapped back afterwards.
    private func step(_ delta: Int) {
        guard isActive, !items.isEmpty else { return }

        let previous = index
        index = (index + delta + items.count) % items.count
        // **R2.** Wrapping past the end is silent, so holding the key looks like the list has
        // stopped moving rather than gone round to the beginning. Detected here rather than in the
        // view, which cannot tell a wrap from an ordinary jump.
        let wrapped = (delta > 0 && index < previous) || (delta < 0 && index > previous)
        if wrapped, Preferences.shared.showsWrapIndicator, items.count > 1 {
            DispatchQueue.main.async { [overlay] in overlay.flashWrap() }
        }
        pushSelection()
    }

    private func pushSelection() {
        let selected = index
        let onSearch = isOnSearch
        DispatchQueue.main.async { [overlay] in
            overlay.select(selected, isOnSearch: onSearch)
        }
        schedulePreview()
    }

    private func commit() {
        guard isActive else { return }
        RuntimeStatus.shared.trace(isOnSearch
            ? "commit on search tile — nothing to raise"
            : "commit index \(index) of \(items.count)")
        // Releasing while on the search tile keeps whatever you were in. There is nothing there to
        // switch to, and switching to an arbitrary window would be the opposite of "let me look".
        let target = isOnSearch ? nil : currentItem
        // Committing to a real window already puts the right thing in front, so undoing the
        // preview first would raise the old window and then immediately raise the new one —
        // one flicker on every switch.
        end(undoingPreview: target == nil)
        guard let target else { return }
        DispatchQueue.main.async { [store] in
            store.raise(target)
        }
    }

    private func cancel() {
        guard isActive else { return }
        end(undoingPreview: true)
    }

    private func end(undoingPreview shouldUndo: Bool) {
        if shouldUndo {
            undoPreview()
        } else {
            cancelPreviewTimer()
            previewedIdentity = nil
        }
        stopClickAwayWatch()
        stopScrollWatch()
        // Remember the query and the selection rather than clear them, so reopening within a few
        // seconds picks up where a mistype left off. See `restoredQuery` and R1.
        lastQuery = query
        lastQueryAt = Date()
        lastSelection = currentItem?.identity
        appFilter = nil
        // The panel is main-actor bound and this runs from the event tap.
        DispatchQueue.main.async { QuickLookPanel.shared.hide() }
        isActive = false
        isOnSearch = false
        previewReturn = nil
        items = []
        allItems = []
        query = ""
        index = 0
        totalCount = 0
        DispatchQueue.main.async { [overlay] in
            overlay.hide()
        }
    }
}
