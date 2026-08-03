import AppKit

/// Checks that run in the binary that ships.
///
/// `assert` compiles out of a release build, so a pass there means nothing. These are plain
/// functions returning failures, invoked by `hexad --self-check`, which the build script fails
/// on. See ~/Developer/macos-app-notes.md.
enum SelfCheck {

    struct Failure {
        let check: String
        let detail: String
    }

    /// A stand-in for a real window in the checks below.
    ///
    /// **Always give it an element.** `WindowItem.isAppOnly` is defined as "has no AX element", so
    /// a fixture built with `element: nil` is an app-only row whatever else it is given — and every
    /// assertion about window behaviour then silently tests the wrong branch. That mistake has now
    /// been made three times in this file, which is twice more than it needs to be made: this
    /// helper is here so it cannot be made a fourth time.
    ///
    /// The system-wide element is a real `AXUIElement` and is never queried — only its existence
    /// matters.
    static func fixture(app: String,
                        title: String,
                        pid: pid_t = 1,
                        minimized: Bool = false,
                        fullScreen: Bool = false,
                        frame: CGRect? = nil) -> WindowItem {
        WindowItem(element: AXUIElementCreateSystemWide(),
                   pid: pid,
                   appName: app,
                   appIcon: nil,
                   title: title,
                   isMinimized: minimized,
                   isFullScreen: fullScreen,
                   frame: frame)
    }

    static func runAll() -> [Failure] {
        var failures: [Failure] = []
        failures += checkAccentResolves()
        failures += checkOklchMath()
        failures += checkOnAccentContrast()
        failures += checkRadiiOrdering()
        failures += checkShortcutModifiers()
        failures += checkSwitcherStateCache()
        failures += checkFuzzyMatch()
        failures += checkKeyBindingMatching()
        failures += checkPopMotion()
        failures += checkAppOnlyEntries()
        failures += checkWindowSort()
        failures += checkWindowIdentity()
        failures += checkActionModifier()
        failures += checkShortcutConflicts()
        failures += checkMatchHighlight()
        failures += checkGridFits()
        failures += checkPinning()
        failures += checkWorkspaceCapture()
        return failures
    }

    /// Pinning exists so ⌘1…⌘9 can point at the same window twice running. That only works if a
    /// pin outranks every other ordering and a slot survives its window disappearing — both are
    /// invisible in a build and both are one wrong line away.
    private static func checkPinning() -> [Failure] {
        var failures: [Failure] = []

        func expect(_ condition: Bool, _ check: String, _ detail: String) {
            if !condition { failures.append(Failure(check: check, detail: detail)) }
        }

        func item(_ app: String, _ title: String) -> WindowItem {
            fixture(app: app, title: title)
        }

        let mail = item("Mail", "Inbox")
        let safari = item("Safari", "News")
        let term = item("Terminal", "zsh")
        let items = [mail, safari, term]

        let empty = PinnedWindows()
        expect(empty.apply(to: items).map(\.title) == items.map(\.title),
               "no pins changes nothing", "an empty pin set reordered the list")

        // A pin outranks the list's own order — that is the whole point.
        let pinned = empty.pinning(term.identity, to: 1)
        expect(pinned.apply(to: items).first?.title == "zsh",
               "a pin leads the list", "the pinned window did not come first")
        expect(pinned.apply(to: items).count == items.count,
               "pinning loses nothing", "the list changed length")

        // Slot order, not list order.
        let two = pinned.pinning(safari.identity, to: 3).pinning(mail.identity, to: 2)
        expect(two.apply(to: items).map(\.appName) == ["Terminal", "Mail", "Safari"],
               "pins sort by slot", "got \(two.apply(to: items).map(\.appName))")

        // Pinning again moves rather than duplicates — two slots for one window would make ⌘2 and
        // ⌘5 both land on it and one of them would never be reachable.
        let moved = pinned.pinning(term.identity, to: 4)
        expect(moved.slot(for: term.identity) == 4,
               "re-pinning moves", "expected slot 4, got \(String(describing: moved.slot(for: term.identity)))")
        expect(moved.apply(to: items).filter { $0.identity == term.identity }.count == 1,
               "re-pinning does not duplicate", "the window appeared twice")

        // Toggling off restores the original order.
        let off = moved.toggling(term.identity)
        expect(!off.isPinned(term.identity), "toggle unpins", "the window stayed pinned")

        // A pin whose window is not on screen must not invent one.
        let ghost = PinnedWindows().pinning("nothing|here|-", to: 1)
        expect(ghost.apply(to: items).count == items.count,
               "a stale pin adds nothing", "a pin with no window changed the list")

        return failures
    }

    /// A window set is only worth having if restoring it puts the right window in front. The
    /// order is reversed on capture precisely so replaying front-to-back ends correctly, which is
    /// exactly the kind of inversion that is invisible until someone uses the feature.
    private static func checkWorkspaceCapture() -> [Failure] {
        var failures: [Failure] = []

        func expect(_ condition: Bool, _ check: String, _ detail: String) {
            if !condition { failures.append(Failure(check: check, detail: detail)) }
        }

        func item(_ app: String) -> WindowItem {
            fixture(app: app, title: app)
        }

        // The store hands back most-recently-used first: Mail is in front.
        let items = [item("Mail"), item("Safari"), item("Terminal")]
        let workspace = WorkspaceStore.capture(items, named: "Writing")

        expect(workspace.identities.count == 3,
               "capture keeps every window", "captured \(workspace.identities.count) of 3")
        // Reversed, so raising them in order leaves Mail — the front window — in front.
        expect(workspace.identities.last == items[0].identity,
               "capture reverses for replay",
               "the front window is not raised last, so it would not end up in front")
        expect(workspace.name == "Writing", "capture keeps the name", "got \(workspace.name)")
        expect(workspace.summary.contains("3 windows"),
               "summary counts windows", "got \(workspace.summary)")

        // App-only rows are not windows and must not be captured — restoring one would open a
        // brand new window nobody asked for.
        let withApp = items + [WindowItem.app(.current)]
        expect(WorkspaceStore.capture(withApp, named: "x").identities.count == 3,
               "capture skips app-only rows", "an app with no windows was captured")

        return failures
    }

    /// The grid's promise is that you see every window at once. That is a geometry claim, and it
    /// is the kind that fails silently — a card too tall by 20pt just pushes the last row out of
    /// sight, and nothing says so. So the solver's own arithmetic is checked against its answer.
    private static func checkGridFits() -> [Failure] {
        var failures: [Failure] = []

        func expect(_ condition: Bool, _ check: String, _ detail: String) {
            if !condition { failures.append(Failure(check: check, detail: detail)) }
        }

        /// The height the plan actually needs — the same arithmetic the view will produce.
        func height(_ plan: GridLayout.Plan, count: Int, headings: Int) -> CGFloat {
            let gap = plan.style == .row ? GridLayout.Compact.gap : GridLayout.Card.gap
            let rows = Int(ceil(Double(count) / Double(max(plan.columns, 1))))
            return CGFloat(rows) * plan.itemHeight + CGFloat(max(rows - 1, 0)) * gap
                + CGFloat(headings) * GridLayout.headingHeight
        }

        // Several real viewports, because the whole failure mode is a layout that fits the screen
        // it was written on. A 13-inch laptop is the tight one.
        let viewports: [(String, CGSize)] = [
            ("laptop", CGSize(width: 1400, height: 780)),
            ("small laptop", CGSize(width: 1100, height: 620)),
            ("large display", CGSize(width: 2400, height: 1300)),
        ]

        for (name, viewport) in viewports {
            // Up to 400: far past what any real desk reaches, which is the point — the promise is
            // "no scroll bar", not "no scroll bar until it gets awkward".
            for count in [1, 4, 9, 20, 40, 80, 150, 250, 400] {
                let plan = GridLayout.plan(groupSizes: [count],
                                           viewport: viewport,
                                           hasHeadings: false)
                let needed = height(plan, count: count, headings: 0)

                expect(plan.columns >= 1, "grid has columns (\(name), \(count))",
                       "solved \(plan.columns) columns")

                // The bug this replaces: a plan that reports a fit and then overflows.
                expect(needed <= viewport.height || plan.overflows,
                       "grid fits or says it cannot (\(name), \(count) windows)",
                       "needed \(Int(needed))pt of \(Int(viewport.height))pt as "
                       + "\(plan.style), and overflows was false")

                if plan.style != .row {
                    let floor = plan.style == .card
                        ? GridLayout.Card.minTitledWidth
                        : GridLayout.Card.minWidth
                    expect(plan.itemWidth >= floor,
                           "grid cards stay readable (\(name), \(count))",
                           "\(plan.style) width fell to \(Int(plan.itemWidth))pt")
                    expect(plan.itemWidth <= GridLayout.Card.maxWidth,
                           "grid cards are not billboards (\(name), \(count))",
                           "card width reached \(Int(plan.itemWidth))pt — B26 again")
                }
            }
        }

        // A realistic busy desk must not have to scroll at all. This is the user-facing promise,
        // stated as a number so it cannot quietly stop being true.
        let busy = GridLayout.plan(groupSizes: [60],
                                   viewport: CGSize(width: 1400, height: 780),
                                   hasHeadings: false)
        expect(!busy.overflows, "60 windows never scroll",
               "the grid gave up and scrolled with 60 windows on a laptop")

        // Few windows must keep proper cards: they are the mode, not a fallback.
        let small = GridLayout.plan(groupSizes: [6],
                                    viewport: CGSize(width: 1400, height: 780),
                                    hasHeadings: false)
        expect(small.style == .card, "six windows keep titled cards",
               "six windows produced \(small.style)")

        // **Never more columns than windows.** LazyVGrid fills fixed columns left to right, so a
        // column beyond the item count is an empty slot that shoves the cards off centre — two
        // cards in a seven-column grid hug the left edge and the panel reads as broken.
        for count in [1, 2, 3, 5] {
            let plan = GridLayout.plan(groupSizes: [count],
                                       viewport: CGSize(width: 2400, height: 1300),
                                       hasHeadings: false)
            expect(plan.columns <= count,
                   "columns never exceed windows (\(count))",
                   "\(count) window(s) laid out in \(plan.columns) columns, leaving empty slots")
        }

        // Multiple display sections cost headings, and the solver must charge for them — this is
        // the case where a fit computed on the total alone comes out one row too tall.
        let split = GridLayout.plan(groupSizes: [30, 30],
                                    viewport: CGSize(width: 1400, height: 780),
                                    hasHeadings: true)
        let splitHeight = height(split, count: 30, headings: 1)
            + height(split, count: 30, headings: 1)
            + GridLayout.betweenSections
        expect(splitHeight <= 780 || split.overflows,
               "two display sections still fit",
               "two sections needed \(Int(splitHeight))pt of 780pt and did not say so")

        return failures
    }

    /// Sorting must not lose or duplicate a window, and "by app" must keep an app's own windows
    /// in the order the store gave them — a sort that reshuffles within a group would undo the
    /// per-window recency the store just worked out.
    private static func checkWindowSort() -> [Failure] {
        var failures: [Failure] = []

        func expect(_ condition: Bool, _ check: String, _ detail: String) {
            if !condition { failures.append(Failure(check: check, detail: detail)) }
        }

        func item(_ app: String, _ title: String) -> WindowItem {
            fixture(app: app, title: title)
        }

        let items = [item("Safari", "News"), item("Mail", "Inbox"),
                     item("Safari", "Docs"), item("Terminal", "zsh")]

        for order in WindowSort.allCases {
            let sorted = order.apply(to: items)
            expect(sorted.count == items.count,
                   "sort keeps every window (\(order.rawValue))",
                   "\(items.count) in, \(sorted.count) out")
        }

        // Recency is the store's own order, untouched.
        expect(WindowSort.recent.apply(to: items).map(\.title) == items.map(\.title),
               "recent sort is a no-op", "recent reordered a list it should have left alone")

        let alphabetical = WindowSort.alphabetical.apply(to: items).map(\.title)
        expect(alphabetical == ["Docs", "Inbox", "News", "zsh"],
               "alphabetical sort", "got \(alphabetical)")

        // Grouped by app, and News before Docs inside Safari because that is how they arrived.
        let byApp = WindowSort.byApp.apply(to: items).map { "\($0.appName)/\($0.title)" }
        expect(byApp == ["Mail/Inbox", "Safari/News", "Safari/Docs", "Terminal/zsh"],
               "by-app sort is stable within an app", "got \(byApp)")

        return failures
    }

    /// Window identity is a heuristic — there is no AX window id without the private call that
    /// clean-room MIT rules out — so the properties it must have are checked rather than assumed.
    /// Get it wrong in the loose direction and two windows share a slot in the recency list; get
    /// it wrong in the strict direction and moving a window forgets it was ever used.
    private static func checkWindowIdentity() -> [Failure] {
        var failures: [Failure] = []

        func expect(_ condition: Bool, _ check: String, _ detail: String) {
            if !condition { failures.append(Failure(check: check, detail: detail)) }
        }

        func window(pid: pid_t, title: String, frame: CGRect?) -> WindowItem {
            fixture(app: "Safari", title: title, pid: pid, frame: frame)
        }

        let base = CGRect(x: 0, y: 0, width: 800, height: 600)
        let moved = CGRect(x: 400, y: 300, width: 800, height: 600)
        let nudged = CGRect(x: 0, y: 0, width: 808, height: 604)
        let resized = CGRect(x: 0, y: 0, width: 1200, height: 900)

        expect(window(pid: 1, title: "News", frame: base).identity
               == window(pid: 1, title: "News", frame: moved).identity,
               "identity survives a move",
               "dragging a window changed its identity, so its recency would be forgotten")

        expect(window(pid: 1, title: "News", frame: base).identity
               == window(pid: 1, title: "News", frame: nudged).identity,
               "identity survives a small resize",
               "an 8pt resize changed the identity — the rounding is too fine")

        expect(window(pid: 1, title: "News", frame: base).identity
               != window(pid: 1, title: "Docs", frame: base).identity,
               "identity separates titles", "two different windows shared one identity")

        expect(window(pid: 1, title: "", frame: base).identity
               != window(pid: 1, title: "", frame: resized).identity,
               "identity separates untitled windows by size",
               "two untitled windows of one app collapsed to one identity")

        expect(window(pid: 1, title: "News", frame: base).identity
               != window(pid: 2, title: "News", frame: base).identity,
               "identity separates processes",
               "two apps with the same window title shared an identity")

        return failures
    }

    /// Square holds a modifier for the whole session, so the action keys cannot use it. If this
    /// ever returned a modifier the binding already holds, ⌥W in Square would type a "w" into the
    /// search box instead of closing a window — and search would eat every action key.
    private static func checkActionModifier() -> [Failure] {
        var failures: [Failure] = []

        func expect(_ condition: Bool, _ check: String, _ detail: String) {
            if !condition { failures.append(Failure(check: check, detail: detail)) }
        }

        for binding in [KeyBinding.commandTab, .optionTab, .optionSpace,
                        KeyBinding(keyCode: Shortcut.Key.tab,
                                   modifiers: CGEventFlags.maskControl.rawValue)] {
            expect(!binding.flags.contains(binding.actionModifier),
                   "action modifier is free (\(binding.label))",
                   "\(binding.label) would use a modifier it already holds")
        }

        expect(KeyBinding.commandTab.actionModifierLabel == "⌥",
               "⌘Tab action modifier",
               "expected ⌥, got \(KeyBinding.commandTab.actionModifierLabel)")
        expect(KeyBinding.optionTab.actionModifierLabel == "⌘",
               "⌥Tab action modifier",
               "expected ⌘, got \(KeyBinding.optionTab.actionModifierLabel)")

        return failures
    }

    /// The conflict table is only useful if it fires on the chords people actually reach for and
    /// stays quiet on the one hexad is built around.
    private static func checkShortcutConflicts() -> [Failure] {
        var failures: [Failure] = []

        func expect(_ condition: Bool, _ check: String, _ detail: String) {
            if !condition { failures.append(Failure(check: check, detail: detail)) }
        }

        let commandQ = KeyBinding(keyCode: Shortcut.Key.q,
                                  modifiers: CGEventFlags.maskCommand.rawValue)
        expect(ShortcutConflicts.conflict(for: commandQ)?.isSevere == true,
               "⌘Q conflicts", "binding ⌘Tab's own Quit chord raised no warning")

        // ⌘Tab is the chord hexad exists to take. Warning about it would be noise on the one
        // binding that ships by default.
        expect(ShortcutConflicts.conflict(for: .commandTab) == nil,
               "⌘Tab is not a conflict", "hexad warned about its own default binding")

        expect(ShortcutConflicts.conflict(for: .optionTab) == nil,
               "⌥Tab is free", "⌥Tab reported a conflict it does not have")

        return failures
    }

    /// The highlight has to agree with the filter. Marking letters the scorer did not match — or
    /// marking any at all in a title the filter is about to drop — is worse than no marks.
    private static func checkMatchHighlight() -> [Failure] {
        var failures: [Failure] = []

        func expect(_ condition: Bool, _ check: String, _ detail: String) {
            if !condition { failures.append(Failure(check: check, detail: detail)) }
        }

        let matched = FuzzyMatch.matchedIndices("sfr", against: "Safari")
        expect(matched == [0, 2, 4],
               "highlight positions", "expected S-f-r at 0,2,4, got \(matched)")

        expect(FuzzyMatch.matchedIndices("xyz", against: "Safari").isEmpty,
               "highlight nothing on a non-match",
               "letters were marked in a title the filter drops")

        expect(FuzzyMatch.matchedIndices("", against: "Safari").isEmpty,
               "highlight nothing for an empty query",
               "an empty query marked characters")

        // Whenever the scorer accepts, the highlighter must mark exactly as many characters as
        // the query has — the two walk the same string and must not disagree.
        for (query, candidate) in [("ma", "Mail"), ("im", "iPhone Mirroring"),
                                   ("term", "Terminal")] {
            let indices = FuzzyMatch.matchedIndices(query, against: candidate)
            let scored = FuzzyMatch.score(query, against: candidate) != nil
            expect(scored == (indices.count == query.count),
                   "highlight agrees with the scorer (\(query))",
                   "scorer said \(scored), highlighter marked \(indices.count) of \(query.count)")
        }

        return failures
    }

    /// A running app with no window is listed too, after every real window. Both halves of that
    /// are load-bearing and neither is visible in a build: an app-only entry that reports a window
    /// element would be raised through AX and silently do nothing, and one that sorted among the
    /// windows would push the window the user wanted away from index 1.
    private static func checkAppOnlyEntries() -> [Failure] {
        var failures: [Failure] = []

        func expect(_ condition: Bool, _ check: String, _ detail: String) {
            if !condition { failures.append(Failure(check: check, detail: detail)) }
        }

        // NSRunningApplication.current is .accessory here, which is exactly the shape the store
        // builds an app-only row from.
        let entry = WindowItem.app(.current)
        expect(entry.isAppOnly,
               "app-only entry",
               "an entry built from an app alone reported a window element")
        expect(entry.element == nil,
               "app-only has no element",
               "an app-only entry carries an AX element, so raising it would go through AX")
        expect(entry.subtitle == "No open windows",
               "app-only subtitle",
               "an app-only entry says \(entry.subtitle) instead of naming its empty state")

        // A real window keeps the app name on the second line — the two must not converge.
        //
        // The element has to be non-nil: `isAppOnly` is defined as "has no window element", so a
        // fixture built with `element: nil` is an app-only row whatever else it is given, and
        // every subtitle assertion below would be testing the wrong branch. The system-wide
        // element is a real `AXUIElement` and is never queried here — only its existence matters.
        let window = fixture(app: "Finder", title: "Screenshots")
        expect(window.displayTitle == "Screenshots",
               "window title wins",
               "a titled window fell back to its app name")

        // A full-screen window has to say so in words as well as in a badge: choosing one takes
        // the whole desktop to another Space, and a marker nobody notices is not a warning.
        let fullScreen = fixture(app: "Safari", title: "News", fullScreen: true)
        expect(fullScreen.subtitle.contains("full screen"),
               "full-screen subtitle",
               "a full-screen window read as \(fullScreen.subtitle)")
        expect(window.subtitle == "Finder",
               "ordinary window subtitle",
               "an ordinary window gained a full-screen note: \(window.subtitle)")

        return failures
    }

    /// A binding that matches too eagerly steals a chord from whatever the user is working in;
    /// one that matches too strictly is a switcher that does not open. Both are silent, and both
    /// are one `isSuperset` away, so the truth table is checked rather than reasoned about.
    private static func checkKeyBindingMatching() -> [Failure] {
        var failures: [Failure] = []

        func expect(_ condition: Bool, _ check: String, _ detail: String) {
            if !condition { failures.append(Failure(check: check, detail: detail)) }
        }

        let commandTab = KeyBinding.commandTab
        let tab = Shortcut.Key.tab

        expect(commandTab.matches(keyCode: tab, flags: .maskCommand),
               "binding matches itself", "⌘Tab did not match a held Command")

        // Shift rides along on purpose — it means "cycle backwards", not "a different chord".
        expect(commandTab.matches(keyCode: tab, flags: [.maskCommand, .maskShift]),
               "binding allows Shift", "⇧⌘Tab should still match ⌘Tab")

        // Any other extra modifier is a different chord and belongs to somebody else.
        expect(!commandTab.matches(keyCode: tab, flags: [.maskCommand, .maskControl]),
               "binding rejects extras", "⌃⌘Tab should not match ⌘Tab")
        expect(!commandTab.matches(keyCode: tab, flags: .maskAlternate),
               "binding rejects wrong modifier", "⌥Tab should not match ⌘Tab")
        expect(!commandTab.matches(keyCode: Shortcut.Key.space, flags: .maskCommand),
               "binding rejects wrong key", "⌘Space should not match ⌘Tab")

        expect(commandTab.label == "⌘Tab",
               "binding label", "expected ⌘Tab, got \(commandTab.label)")
        expect(commandTab.holdModifier == .maskCommand,
               "binding hold modifier", "⌘Tab should commit on Command release")

        // A binding with nothing to hold cannot end on key-up, and the strip has to know that
        // or it waits forever for a release that never comes.
        let bare = KeyBinding(keyCode: 105, modifiers: 0)
        expect(!bare.isHoldable, "modifier-less binding", "F13 alone must not be holdable")

        // Exactly one mode cycles while held. If that ever became two, the palette would be
        // opened by a key the user is still holding down and would close on release.
        let held = SwitcherMode.allCases.filter(\.isHeldToCycle)
        expect(held == [.square],
               "one held-to-cycle mode", "expected only square, got \(held.map(\.rawValue))")

        return failures
    }

    /// The pop is a fade *and* a scale. Get a sign wrong and the overlay grows as it leaves or
    /// starts larger than it ends, which reads as a glitch rather than as motion.
    private static func checkPopMotion() -> [Failure] {
        let pop = Theme.Motion.Pop.self
        var failures: [Failure] = []

        if !(pop.from < 1) {
            failures.append(Failure(check: "pop grows inward",
                                    detail: "from is \(pop.from); it must start below 1"))
        }
        if !(pop.overshoot > 1) {
            failures.append(Failure(check: "pop overshoots",
                                    detail: "overshoot is \(pop.overshoot); it must exceed 1"))
        }
        if !(pop.to < 1) {
            failures.append(Failure(check: "pop shrinks away",
                                    detail: "to is \(pop.to); a panel must not grow as it leaves"))
        }
        // Leaving is quicker than arriving: motion after the decision is only latency.
        if !(pop.outDuration < pop.inDuration) {
            failures.append(Failure(check: "pop out is quicker",
                                    detail: "out \(pop.outDuration) is not under in \(pop.inDuration)"))
        }
        return failures
    }

    /// The palette's whole claim is that three letters find the window you meant. That is a
    /// ranking property, not a filtering one, so it gets checked rather than eyeballed — a
    /// scorer that quietly stops preferring word starts still "works" and is useless.
    private static func checkFuzzyMatch() -> [Failure] {
        var failures: [Failure] = []

        func expect(_ condition: Bool, _ check: String, _ detail: String) {
            if !condition { failures.append(Failure(check: check, detail: detail)) }
        }

        expect(FuzzyMatch.score("sfr", against: "Safari") != nil,
               "fuzzy subsequence", "\"sfr\" should match \"Safari\"")
        expect(FuzzyMatch.score("xyz", against: "Safari") == nil,
               "fuzzy rejects", "\"xyz\" should not match \"Safari\"")
        expect(FuzzyMatch.score("", against: "Safari") == 0,
               "fuzzy empty query", "an empty query should score 0, not fail to match")

        // Word starts beat scattered letters: "im" is iPhone Mirroring, not Vim.
        let initials = FuzzyMatch.score("im", against: "iPhone Mirroring") ?? -1
        let scattered = FuzzyMatch.score("im", against: "Interactive Media Manager Diagram") ?? -1
        expect(initials > scattered, "fuzzy word starts",
               "initials scored \(initials), scattered scored \(scattered)")

        // Shorter wins ties.
        let short = FuzzyMatch.score("mail", against: "Mail") ?? -1
        let long = FuzzyMatch.score("mail", against: "Mailbox Settings") ?? -1
        expect(short > long, "fuzzy prefers shorter",
               "\"Mail\" scored \(short), \"Mailbox Settings\" scored \(long)")

        // Ranking drops non-matches and orders by score.
        let ranked = FuzzyMatch.rank(["Terminal", "Safari", "Mail"], query: "ma") { $0 }
        expect(ranked.first == "Mail", "fuzzy ranking",
               "expected Mail first for \"ma\", got \(ranked)")

        return failures
    }

    /// The event tap reads `cachedState`, never `state`. If the cache is never populated it
    /// stays `.unsupported`, hexad silently pins itself to ⌥Tab, and ⌘Tab appears to be
    /// "not implemented" with nothing in the logs. Cheap to check, expensive to debug.
    private static func checkSwitcherStateCache() -> [Failure] {
        let live = SystemSwitcher.state
        let cached = SystemSwitcher.refreshCachedState()
        guard cached != live else { return [] }
        return [Failure(check: "switcher state cache",
                        detail: "refresh produced \(cached) but the live state is \(live)")]
    }

    /// A switcher bound to the wrong modifier is dead on arrival and looks identical to one
    /// that never started. Swapping `.maskCommand` and `.maskAlternate` is a one-character
    /// mistake, so it gets a check rather than a careful reading.
    private static func checkShortcutModifiers() -> [Failure] {
        var failures: [Failure] = []

        if !Shortcut.commandTab.isHeld(in: .maskCommand) {
            failures.append(Failure(check: "⌘Tab modifier",
                                    detail: "commandTab did not match a held Command flag"))
        }
        if Shortcut.optionTab.isHeld(in: .maskCommand) {
            failures.append(Failure(check: "⌥Tab modifier",
                                    detail: "optionTab matched Command — the modifiers are swapped"))
        }
        // Tab is 48 on every layout. A changed constant means every hotkey silently stops.
        if Shortcut.commandTab.keyCode != 48 || Shortcut.optionTab.keyCode != 48 {
            failures.append(Failure(check: "Tab key code",
                                    detail: "expected virtual key 48 for Tab"))
        }
        return failures
    }

    /// A colour that comes back black means the bridge resolved against the wrong environment —
    /// the `NSColor(Color)` trap. Cheap insurance. design-language.md §2.
    private static func checkAccentResolves() -> [Failure] {
        let accent = Palette.Light.accent
        let isBlack = accent.r < 0.02 && accent.g < 0.02 && accent.b < 0.02
        guard isBlack else { return [] }
        return [Failure(check: "accent resolves",
                        detail: "light accent resolved to black — check the NSColor bridge")]
    }

    /// Known conversions, so a hand-edited constant fails a build instead of looking
    /// slightly wrong forever.
    private static func checkOklchMath() -> [Failure] {
        var failures: [Failure] = []

        // Pure white: L=1, C=0 maps to 1,1,1 in sRGB regardless of hue.
        let white = Palette.oklch(1.0, 0, 0)
        if abs(white.r - 1) > 0.01 || abs(white.g - 1) > 0.01 || abs(white.b - 1) > 0.01 {
            failures.append(Failure(check: "oklch white",
                                    detail: "L=1 C=0 gave \(fmt(white)), expected 1,1,1"))
        }

        // Pure black.
        let black = Palette.oklch(0, 0, 0)
        if black.r > 0.01 || black.g > 0.01 || black.b > 0.01 {
            failures.append(Failure(check: "oklch black",
                                    detail: "L=0 C=0 gave \(fmt(black)), expected 0,0,0"))
        }

        // Amber at hue 70 must be warm: red channel clearly ahead of blue.
        let accent = Palette.Light.accent
        if accent.r <= accent.b {
            failures.append(Failure(check: "accent is warm",
                                    detail: "hue \(Palette.accentHue) gave \(fmt(accent)); "
                                          + "red should exceed blue for amber"))
        }
        return failures
    }

    /// Amber is a light accent, so its label must be a dark ink. Getting this backwards is
    /// unreadable rather than merely ugly. design-language.md §2.
    private static func checkOnAccentContrast() -> [Failure] {
        func luminance(_ ink: Palette.Ink) -> Double {
            0.2126 * ink.r + 0.7152 * ink.g + 0.0722 * ink.b
        }
        var failures: [Failure] = []
        for (name, accent, onAccent) in [
            ("light", Palette.Light.accent, Palette.Light.onAccent),
            ("dark", Palette.Dark.accent, Palette.Dark.onAccent),
        ] {
            if luminance(onAccent) >= luminance(accent) {
                failures.append(Failure(
                    check: "onAccent contrast (\(name))",
                    detail: "onAccent is not darker than the accent it sits on"))
            }
        }
        return failures
    }

    /// The overlay radii are additions to the shared scale and must stay ordered against it,
    /// or the overlay stops reading as one family. PLAN.md §10.
    private static func checkRadiiOrdering() -> [Failure] {
        let ordered = Theme.Radius.control < Theme.Radius.card
            && Theme.Radius.card < Theme.Radius.tile
            && Theme.Radius.tile < Theme.Radius.overlay
        guard !ordered else { return [] }
        return [Failure(check: "radius ordering",
                        detail: "expected control < card < tile < overlay")]
    }

    private static func fmt(_ ink: Palette.Ink) -> String {
        String(format: "%.3f,%.3f,%.3f", ink.r, ink.g, ink.b)
    }
}
