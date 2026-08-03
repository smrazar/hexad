import AppKit
import ApplicationServices

/// The list of windows, kept warm.
///
/// PLAN.md §11: enumeration never happens on the hot path. Pressing the hotkey must not walk
/// every app's window list — that walk is tens of milliseconds and it is exactly why other
/// switchers feel like they hesitate. So the list is rebuilt when the world changes (an app
/// activates, launches, quits, hides) and the overlay reads a cache.
///
/// Order is most-recently-used **by app**, then that app's own windows in the order they were
/// last used — see `windowOrder` and `WindowItem.identity` for how a window is recognised again
/// without the private call clean-room MIT rules out.
final class WindowStore {

    /// How often the background timer refreshes the cache. A backstop for changes that fire no
    /// notification — a window closed inside an app that stays frontmost, say.
    private static let stalenessInterval: TimeInterval = 2.0

    /// A deny-list, because the allow-list version of this shipped finding one window in four.
    /// String literals because AppKit exports no symbol for these two subroles — only for the
    /// roles. Sheets are already excluded by the role check; a system alert is not.
    private static let excludedSubroles: Set<String> = ["AXSheet", "AXSystemDialog"]

    /// One app must never stall the whole walk. AX is synchronous and a hung app would otherwise
    /// freeze the switcher — PLAN.md §4 lists this as a Medium risk and it had no mitigation.
    ///
    /// **Raised from 0.25s to 1.0s**, which is affordable now that the walk runs off the main
    /// thread. A quarter-second was chosen when a slow app would have stalled the UI, and it was
    /// too tight for a browser with many windows: each window costs several AX round trips, and a
    /// timed-out read is indistinguishable from "not a window" unless the error is inspected —
    /// so windows were being dropped for being slow. See `windows(of:)`.
    private static let messagingTimeout: Float = 1.0

    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// System processes that own a window but are never somewhere a user switches *to*.
    ///
    /// `loginwindow` is the one that matters: while the screen is locked it owns a window titled
    /// "Login", and hexad listed it as an ordinary switchable window — so the switcher offered to
    /// raise the lock screen. Found by a screenshot that came back black, which is what a locked
    /// screen looks like, with `--dump-windows` reporting "loginwindow Login" at index 0.
    ///
    /// A deny-list by bundle identifier rather than a rule, because there is no property that
    /// distinguishes these from ordinary windows — they are ordinary windows, belonging to
    /// processes a person cannot switch to.
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.SecurityAgent",
    ]

    /// How many window identities to remember. Far more than anyone has open, and bounded so a
    /// machine left running for a week does not accumulate an unbounded list of dead windows.
    private static let windowOrderLimit = 400

    private var cache: [WindowItem] = []
    private var lastRebuild: Date = .distantPast
    /// Front of the array is most recent.
    private var appOrder: [pid_t] = []
    /// Per-window recency, front-most first, keyed by `WindowItem.identity`.
    ///
    /// This is what makes two windows of one app come back in the order they were *used* rather
    /// than in the order AX happens to report them. It is only consulted within an app: the top
    /// level of the list stays app-MRU, because ⌘Tab has meant "the last app" on this platform
    /// for twenty years and reordering across apps by window would break that.
    private var windowOrder: [String] = []
    private var observers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    /// Serial on purpose — two overlapping walks would race to publish, and the older one could
    /// win. See `rebuildInBackground`.
    private let walkQueue = DispatchQueue(label: "com.smrazar.hexad.window-walk", qos: .userInitiated)
    private var isWalking = false
    private var needsAnotherWalk = false
    /// What vanished between two passes. Fed from `apply`, read by the switcher's reopen list.
    let closed = ClosedWindows()

    // MARK: - Lifecycle

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] note in
                self?.handle(note)
            }
            observers.append(token)
        }
        seedAppOrder()
        rebuild()
        startRefreshTimer()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Keeps the cache fresh in the background, so the hot path never has to.
    ///
    /// Most changes arrive as workspace notifications; this covers the ones that fire none — a
    /// window closed inside an app that stays frontmost, a title changing as a document is saved.
    /// `.common` mode so it keeps running while a menu or a panel is up, which is exactly when
    /// the list is about to be read.
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: Self.stalenessInterval, repeats: true) { [weak self] _ in
            guard let self,
                  Date().timeIntervalSince(self.lastRebuild) >= Self.stalenessInterval
            else { return }
            self.rebuildInBackground()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func handle(_ note: Notification) {
        if note.name == NSWorkspace.didActivateApplicationNotification,
           let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            promote(app.processIdentifier)
        }
        // Off the main thread: this fires on every app activation, and the walk is tens of
        // milliseconds. Switching apps is exactly when the machine should feel quickest.
        rebuildInBackground()
    }

    /// hexad launches into a machine that already has a window order. Without this, the first
    /// ⌘Tab after launch shows an arbitrary order and reads as broken.
    private func seedAppOrder() {
        appOrder = switchableApps().map(\.processIdentifier)
    }

    private func promote(_ pid: pid_t) {
        appOrder.removeAll { $0 == pid }
        appOrder.insert(pid, at: 0)
    }

    /// Remember that this exact window was just used. Called on every raise, which is the only
    /// moment hexad knows for certain which window someone chose.
    private func promote(window item: WindowItem) {
        guard !item.isAppOnly else { return }
        let key = item.identity
        windowOrder.removeAll { $0 == key }
        windowOrder.insert(key, at: 0)
        if windowOrder.count > Self.windowOrderLimit {
            windowOrder.removeLast(windowOrder.count - Self.windowOrderLimit)
        }
    }

    /// Order one app's windows by when each was last used, keeping anything never seen before in
    /// the AX order it arrived in — behind everything hexad has a record of.
    private func byRecency(_ items: [WindowItem]) -> [WindowItem] {
        guard items.count > 1 else { return items }
        return items.enumerated().sorted { lhs, rhs in
            let left = windowOrder.firstIndex(of: lhs.element.identity) ?? Int.max
            let right = windowOrder.firstIndex(of: rhs.element.identity) ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    // MARK: - Reading

    /// What the overlay opens on. **Never enumerates.** Returns the cache and nothing else.
    ///
    /// This used to rebuild inline whenever the cache was older than `stalenessInterval`, which
    /// put the full AX walk straight onto the keypress it was written to keep off it. Measured
    /// with `--self-check --bench` on a four-window desk: the cached read is 0.000ms and the walk
    /// is 22ms median, 50ms worst — against PLAN.md §11's 16ms budget for the whole open. The
    /// backstop was doing the exact damage the cache exists to prevent, on the majority of opens,
    /// because two seconds without an app activation is the normal state of a machine.
    ///
    /// Freshness is the refresh timer's job now, not the reader's.
    func snapshot() -> [WindowItem] {
        cache
    }

    /// Everything about one app that the AX walk needs, read on the main thread before the walk
    /// leaves it. `NSRunningApplication` and `NSImage` are AppKit objects; the walk is not.
    private struct AppFacts {
        let pid: pid_t
        let name: String
        let icon: NSImage?
        let isRegular: Bool
    }

    /// The current front window's app sits at index 0, so a switcher opening on index 1 lands
    /// on "the last thing I was in" — the behaviour every ⌘Tab user already has in their hands.
    ///
    /// Synchronous, and kept that way for `--dump-windows`, `--self-check --bench` and the demo
    /// modes, which have no run loop to wait on. Everything in the running app goes through
    /// `rebuildInBackground` instead.
    func rebuild() {
        guard Permissions.isAccessibilityGranted else {
            cache = []
            lastRebuild = Date()
            return
        }
        let facts = appFacts()
        apply(walk(facts))
    }

    /// The same walk, off the main thread.
    ///
    /// The walk is 14ms median and 47ms worst on a four-window desk — and it runs on every app
    /// activation, so on a busy machine the main thread pays it constantly. It is not on the
    /// hotkey path (see `snapshot`), but a 47ms stall on the main thread while switching apps is
    /// hexad making the *system* hitch, which is worse than hexad being slow.
    ///
    /// AppKit is touched only before the hop out and after the hop back: the app list, names and
    /// icons are read here, the AX calls run on a serial queue, and the result is assigned on
    /// main. One queue, not a concurrent one — two overlapping walks would race to publish and
    /// the older one could win.
    func rebuildInBackground() {
        guard Permissions.isAccessibilityGranted else {
            cache = []
            lastRebuild = Date()
            return
        }
        // Coalesce: an app launch fires several notifications in a row, and walking four times to
        // publish the last answer is three walks of pure waste.
        guard !isWalking else {
            needsAnotherWalk = true
            return
        }
        isWalking = true

        let facts = appFacts()
        walkQueue.async { [weak self] in
            guard let self else { return }
            let result = self.walk(facts)
            DispatchQueue.main.async {
                self.apply(result)
                self.isWalking = false
                if self.needsAnotherWalk {
                    self.needsAnotherWalk = false
                    self.rebuildInBackground()
                }
            }
        }
    }

    /// Main-thread half: who is running, in most-recently-used order.
    private func appFacts() -> [AppFacts] {
        switchableApps()
            .sorted { rank($0.processIdentifier) < rank($1.processIdentifier) }
            .map { AppFacts(pid: $0.processIdentifier,
                            name: $0.localizedName ?? "Unknown",
                            icon: $0.icon,
                            isRegular: $0.activationPolicy == .regular) }
    }

    /// The AX half. Pure with respect to the store — it reads `windowOrder` for per-window
    /// recency and nothing else, so it is safe to run off the main thread as long as nothing
    /// mutates that while it runs, which only `raise` does and only from main.
    private func walk(_ facts: [AppFacts]) -> [WindowItem] {
        // Two tiers, and the order between them is the whole point: everything with a window
        // first, in MRU order, then the running apps that have none. A windowless app listed
        // among real windows pushes the window you actually wanted further from index 1.
        var windowed: [WindowItem] = []
        var windowless: [WindowItem] = []

        for app in facts {
            // Within one app, the order is per-window recency — AX order only breaks ties among
            // windows hexad has never seen chosen.
            let found = byRecency(windows(of: app))
            if !found.isEmpty {
                windowed += found
            } else if app.isRegular {
                // Only Dock apps earn an app-only row. An .accessory app with no window is a
                // background agent — there is nothing there to switch to.
                windowless.append(WindowItem(element: nil, pid: app.pid, appName: app.name,
                                             appIcon: app.icon, title: "", isMinimized: false,
                                             isFullScreen: false, frame: nil))
            }
        }
        return windowed + windowless
    }

    /// Main-thread half: filter, sort, publish.
    ///
    /// The display filter reads `NSEvent.mouseLocation` and `NSScreen`, so it belongs here rather
    /// than in the walk — and it is cheap, unlike the walk.
    private func apply(_ walked: [WindowItem]) {
        let windowless = walked.filter(\.isAppOnly)
        var windowed = walked.filter { !$0.isAppOnly }

        if Preferences.shared.limitsToActiveDisplay {
            windowed = onActiveDisplay(windowed)
        } else {
            didFallBackFromDisplayFilter = false
        }
        windowed = Preferences.shared.sortOrder.apply(to: windowed)
        // Pins outrank the sort — that is the whole point of pinning, so it is applied last.
        windowed = Preferences.shared.pinned.apply(to: windowed)

        cache = windowed + windowless
        lastRebuild = Date()
        // Diff against the previous pass to notice what was closed. Free: the list is already
        // built, and nothing else knows both what was there and what is there now.
        closed.observe(cache)
        NotificationCenter.default.post(name: .hexadMenuBarChanged, object: nil)
        RuntimeStatus.shared.trace("rebuilt · \(windowed.count) windows"
            + " + \(windowless.count) windowless apps")
    }

    /// Keep only the windows on the display the pointer is on.
    ///
    /// The *pointer*, not `NSScreen.main`: main is the screen with the key window, which while a
    /// switcher is opening is whatever you are switching away from — so filtering by it would
    /// answer the wrong question on the one press it matters.
    ///
    /// Only the Space half of this is deferred. `CGSCopySpacesForWindows` is private and hexad
    /// stays clean-room MIT, so "this Space only" is not offered at all rather than offered and
    /// wrong. docs/TODO.md F4.
    private func onActiveDisplay(_ items: [WindowItem]) -> [WindowItem] {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return items }
        let pointer = NSEvent.mouseLocation
        guard let active = screens.first(where: { $0.frame.contains(pointer) }) ?? screens.first
        else { return items }

        let filtered = items.filter { item in
            guard let frame = item.frame else { return true }
            return active.frame.intersects(flipToScreenSpace(frame, screens: screens))
        }
        // Never filter the list down to nothing. An empty switcher is indistinguishable from a
        // broken one, and "no windows on this display" is not worth showing a dead panel for.
        //
        // **R3.** The fallback used to be silent, which is its own kind of lie: the switcher
        // showed every window while the setting said "only this display", and there was no way to
        // tell that from the filter having done nothing. It now records that it fell back, and
        // the overlay says so.
        didFallBackFromDisplayFilter = filtered.isEmpty
        return filtered.isEmpty ? items : filtered
    }

    /// True when "only this display" was asked for and produced nothing, so everything is being
    /// shown instead. Read by the overlay header.
    private(set) var didFallBackFromDisplayFilter = false

    /// AX y grows downward from the top of the primary display; NSScreen y grows upward from its
    /// bottom. Same pivot as `DisplayGrouping`.
    private func flipToScreenSpace(_ rect: CGRect, screens: [NSScreen]) -> CGRect {
        guard let primary = screens.first else { return rect }
        return CGRect(x: rect.origin.x,
                      y: primary.frame.maxY - rect.origin.y - rect.height,
                      width: rect.width,
                      height: rect.height)
    }

    private func rank(_ pid: pid_t) -> Int {
        appOrder.firstIndex(of: pid) ?? Int.max
    }

    private func switchableApps() -> [NSRunningApplication] {
        let excluded = Preferences.shared.excludedBundleIDs
        return NSWorkspace.shared.runningApplications.filter {
            guard !$0.isTerminated else { return false }
            // The lock screen and the screen saver own windows and are not switchable.
            if let bundleID = $0.bundleIdentifier,
               Self.excludedBundleIDs.contains(bundleID) {
                return false
            }
            // A deny-list of apps nobody switches to. hexad itself can never be excluded — its
            // Settings window is sometimes the only way back into the app.
            if let bundleID = $0.bundleIdentifier,
               $0.processIdentifier != Self.ownPID,
               excluded.contains(bundleID) {
                return false
            }
            // .regular is every app in the Dock. .accessory is included too, but only earns a row
            // by actually owning a window — a menu bar app's Settings window is somewhere a user
            // switches to, and excluding the whole activation policy is why hexad's own Settings
            // window was missing from hexad's own switcher.
            return $0.activationPolicy == .regular || $0.activationPolicy == .accessory
        }
    }

    // MARK: - Diagnosis

    /// Why the window list looks the way it does, app by app.
    ///
    /// Exists because "the switcher is missing my windows" has half a dozen possible causes that
    /// all look identical from outside: the app was filtered out, AX refused the query, the query
    /// timed out, or every window was dropped by the role or subrole rules. Guessing between them
    /// cost a round; this prints the answer. `hexad --dump-windows --why`.
    func diagnose() -> String {
        var lines: [String] = []
        lines.append("Accessibility: \(Permissions.isAccessibilityGranted ? "granted" : "DENIED")")
        lines.append("messaging timeout: \(Self.messagingTimeout)s")
        lines.append("")

        for app in appFacts() {
            let axApp = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(axApp, Self.messagingTimeout)

            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw)
            let elements = (raw as? [AXUIElement]) ?? []

            var kept = 0
            var reasons: [String: Int] = [:]
            for element in elements {
                var roleRaw: CFTypeRef?
                let roleError = AXUIElementCopyAttributeValue(
                    element, kAXRoleAttribute as CFString, &roleRaw)
                let role = roleRaw as? String
                if roleError != .success {
                    reasons["role read failed (\(describe(roleError)))", default: 0] += 1
                    continue
                }
                guard role == kAXWindowRole else {
                    reasons["role \(role ?? "nil")", default: 0] += 1
                    continue
                }
                let subrole: String? = axCopy(element, kAXSubroleAttribute)
                if let subrole, Self.excludedSubroles.contains(subrole) {
                    reasons["subrole \(subrole)", default: 0] += 1
                    continue
                }
                kept += 1
            }

            let summary = reasons.isEmpty
                ? ""
                : "  dropped: " + reasons.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
            lines.append(String(format: "%-28@ pid %-7d ax=%-16@ raw %2d  kept %2d%@",
                                app.name as NSString, app.pid,
                                describe(error) as NSString,
                                elements.count, kept, summary as NSString))
        }
        return lines.joined(separator: "\n")
    }

    private func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .apiDisabled: return "apiDisabled"
        case .notImplemented: return "notImplemented"
        case .cannotComplete: return "cannotComplete"
        case .invalidUIElement: return "invalidElement"
        case .attributeUnsupported: return "noAttribute"
        case .noValue: return "noValue"
        default: return "error \(error.rawValue)"
        }
    }

    // MARK: - Accessibility

    private func windows(of app: AppFacts) -> [WindowItem] {
        let pid = app.pid
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Self.messagingTimeout)
        guard let raw: [AXUIElement] = axCopy(axApp, kAXWindowsAttribute) else { return [] }

        let name = app.name
        let icon = app.icon
        let found: [WindowItem] = raw.compactMap { element in
            // Role, not subrole. macOS reports plenty of ordinary windows as `AXDialog` —
            // Finder's file browser and Terminal's window both do on macOS 26 — so an
            // allow-list of `AXStandardWindow` finds almost nothing. docs/BUGS.md B2.
            //
            // Role also excludes the thing that most looks like a window and is not: the Finder
            // desktop, which arrives in the same list as an `AXScrollArea`.
            //
            // **A failed read is not a wrong answer.** `axCopy` returns nil both when the app
            // says "this is a scroll area" and when it says nothing at all because the query
            // timed out — and treating those the same silently dropped windows for being slow,
            // which is exactly what a browser with many windows is. The error is inspected, so a
            // window that cannot answer is kept: it is in the app's own window list, which is
            // evidence enough. Only a definite wrong role gets it dropped.
            var roleRaw: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString,
                                                          &roleRaw)
            if roleError == .success {
                guard (roleRaw as? String) == kAXWindowRole else { return nil }
            } else {
                RuntimeStatus.shared.trace(
                    "kept an unreadable window of \(name) (\(self.describe(roleError)))")
            }

            // Sheets and system dialogs are attached to another window rather than being
            // somewhere a user switches *to*.
            let subrole: String = axCopy(element, kAXSubroleAttribute) ?? ""
            if Self.excludedSubroles.contains(subrole) { return nil }

            // hexad's own process is the one place a stricter rule is needed. Its Settings and
            // onboarding windows are ordinary titled windows and belong in the list; its strip,
            // palette, grid and backdrop are borderless panels and must never appear in the very
            // list they are drawing. Requiring the standard subrole separates the two exactly.
            if pid == Self.ownPID, subrole != (kAXStandardWindowSubrole as String) { return nil }

            let minimized: Bool = axCopy(element, kAXMinimizedAttribute) ?? false
            // `AXFullScreen` is a documented attribute, not a private call — apps that adopt the
            // standard full-screen button publish it. A window that does not answer is simply not
            // full screen, which is the right default: the flag only adds a marker and changes
            // how the window is raised, so a false negative costs a badge and nothing more.
            let fullScreen: Bool = axCopy(element, "AXFullScreen") ?? false
            return WindowItem(element: element,
                              pid: pid,
                              appName: name,
                              appIcon: icon,
                              title: axCopy(element, kAXTitleAttribute) ?? "",
                              isMinimized: minimized,
                              isFullScreen: fullScreen,
                              subrole: subrole,
                              frame: axFrame(element))
        }
        return deduplicated(found)
    }

    /// Finder hands back the *same* window twice — once as `AXSystemFloatingWindow` and once as
    /// `AXStandardWindow`, same title, same frame. Listing a window twice makes the switcher look
    /// like it is double-counting, and cycling through it feels stuck.
    ///
    /// **This used to key on title + frame, and that ate real windows.** A browser reports its
    /// window title as the active tab's title, so two Vivaldi windows showing the same page — or
    /// two freshly opened ones, or two sitting maximised at the identical frame — looked like one
    /// window to this rule and one of them silently vanished from the switcher. The same applies
    /// to any two same-size untitled windows: minimized windows report no frame at all, so every
    /// minimized window of an app collapsed into a single entry.
    ///
    /// Identity now comes from the AX element itself, which is exact: two different windows are
    /// never the same element, and a window handed back twice always is. The title-and-frame rule
    /// survives only where it was actually needed — against a *floating* duplicate of a window
    /// that is already in the list — so it can no longer merge two ordinary windows.
    private func deduplicated(_ items: [WindowItem]) -> [WindowItem] {
        var seenElements: [AXUIElement] = []
        var byElement: [WindowItem] = []
        for item in items {
            guard let element = item.element else {
                byElement.append(item)
                continue
            }
            // CFEqual, not ==: AXUIElement is a CFType, and reference comparison would treat two
            // handles to one window as two windows.
            if seenElements.contains(where: { CFEqual($0, element) }) { continue }
            seenElements.append(element)
            byElement.append(item)
        }

        // The Finder case, narrowed to the subrole that caused it.
        let anchors = Set(byElement.filter { $0.subrole != Self.floatingSubrole }
            .map(Self.shapeKey))
        return byElement.filter { item in
            guard item.subrole == Self.floatingSubrole else { return true }
            return !anchors.contains(Self.shapeKey(item))
        }
    }

    private static let floatingSubrole = "AXSystemFloatingWindow"

    private static func shapeKey(_ item: WindowItem) -> String {
        let frame = item.frame ?? .zero
        return "\(item.title)|\(Int(frame.origin.x)),\(Int(frame.origin.y))"
            + "|\(Int(frame.width))×\(Int(frame.height))"
    }

    // MARK: - Acting

    /// Bring a window to the front. Three steps, and skipping any one of them fails in a way
    /// that looks like the switcher "didn't work":
    /// un-minimize (a raise on a minimized window is silently ignored), raise within its app,
    /// then activate the app itself (raising alone leaves the old app owning the menu bar).
    /// `remember: false` raises without touching the recency order — what "hold to preview" needs.
    /// A peek is not a choice, and recording it would let a slow scroll rewrite the MRU list into
    /// the order the user scrolled past rather than the order they used.
    func raise(_ item: WindowItem, remember: Bool = true) {
        guard remember else {
            peek(item)
            return
        }
        let pid = item.pid
        // An app-only entry has no window to raise, so the action is to **give it one**.
        //
        // Activating alone just moves the menu bar to an app with nothing on screen, which looks
        // like the switcher did nothing. Asking Launch Services to open an already-running app
        // sends it the reopen event instead — the same one a Dock icon click sends — and the
        // documented response to that is to open a new window. Finder gives a new browser window,
        // a text editor an untitled document, and an app that genuinely has nothing to show simply
        // comes forward, which is the correct outcome for it.
        guard let element = item.element else {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            promote(pid)
            guard let bundleURL = app.bundleURL else {
                app.activate()
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // `createsNewApplicationInstance` stays false on purpose: this must reach the running
            // process, not launch a second copy of it.
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) {
                _, error in
                if error != nil {
                    DispatchQueue.main.async { app.activate() }
                }
            }
            return
        }

        if item.isMinimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                         kCFBooleanFalse)
        }

        // A full-screen window lives in a Space of its own, and `AXRaise` cannot move the desktop
        // to another Space — only activating the app does that. Raising first would therefore
        // "succeed" against a window nobody can see, and hexad would look like it had done
        // nothing. Activate first, then raise once we are on the right Space.
        if item.isFullScreen {
            NSRunningApplication(processIdentifier: pid)?.activate()
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            promote(pid)
            promote(window: item)
            return
        }

        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
        promote(pid)
        promote(window: item)
    }

    /// Raise without recording it. App-only entries are skipped entirely: giving an app a brand
    /// new window is not something to do speculatively while someone is still deciding.
    private func peek(_ item: WindowItem) {
        guard let element = item.element, !item.isMinimized else { return }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: item.pid)?.activate()
    }

    /// Close a window without switching to it. There is no "close" action in AX — the close
    /// button is an element, and pressing it is the documented way to do this.
    func close(_ item: WindowItem) {
        guard let element = item.element,
              let button: AXUIElement = axCopy(element, kAXCloseButtonAttribute)
        else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    func minimize(_ item: WindowItem) {
        guard let element = item.element else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    /// Quit the app this window belongs to — ⌘Q on the selection.
    ///
    /// `terminate`, never `forceTerminate`: an app with unsaved work must get its chance to say
    /// so. That means a document app may put up a save sheet and stay running, which is correct
    /// even though it makes the switcher look like the quit did nothing.
    ///
    /// hexad refuses to quit itself. Doing it from inside the switcher would tear down the panel
    /// mid-gesture, and there is a Quit button in Settings ▸ About for when it is meant.
    func quit(_ item: WindowItem) {
        guard item.pid != Self.ownPID,
              let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        RuntimeStatus.shared.trace("quit \(item.appName)")
        app.terminate()
    }

    /// Hide or unhide the app — the ⌘H equivalent, and its undo.
    ///
    /// A hidden app keeps its windows in the list, because hiding is not closing and a switcher
    /// that forgets a hidden app is a switcher you cannot use to get it back.
    func toggleHidden(_ item: WindowItem) {
        guard item.pid != Self.ownPID,
              let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        RuntimeStatus.shared.trace("\(app.isHidden ? "unhide" : "hide") \(item.appName)")
        _ = app.isHidden ? app.unhide() : app.hide()
    }

    /// Move a window to another display — the grid's drag.
    ///
    /// It lands **centred** on the target rather than at the matching relative position. Centring
    /// is predictable and always fits; preserving the relative position means a window dragged
    /// from a large display to a small one arrives half off the edge, which reads as hexad having
    /// thrown it away.
    ///
    /// A full-screen window is refused. It owns a Space, and setting its position does nothing
    /// while looking like it should have — the honest answer is to decline.
    @discardableResult
    func move(_ item: WindowItem, toScreen index: Int) -> Bool {
        let screens = NSScreen.screens
        guard let element = item.element, let frame = item.frame,
              !item.isFullScreen,
              screens.indices.contains(index), let primary = screens.first
        else { return false }

        let target = screens[index]
        // NSScreen y grows upward from the bottom of the primary display; AX y grows downward
        // from its top. The primary screen's maxY is the pivot for both — same conversion as
        // DisplayGrouping, in the other direction.
        let topLeftY = primary.frame.maxY - target.frame.maxY
        let origin = CGPoint(
            x: target.frame.minX + max(0, (target.frame.width - frame.width) / 2),
            y: topLeftY + max(0, (target.frame.height - frame.height) / 2))

        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        RuntimeStatus.shared.trace("move \(item.displayTitle) → display \(index + 1)"
            + " · \(result == .success ? "ok" : "refused")")
        return result == .success
    }

    /// Everything currently listed, unfiltered — what a workspace capture works from.
    var allItems: [WindowItem] { cache }

    /// How many windows in the current list belong to each pid, so a card can say "3 windows"
    /// without every view walking the list itself.
    func windowCounts() -> [pid_t: Int] {
        cache.reduce(into: [:]) { counts, item in
            guard !item.isAppOnly else { return }
            counts[item.pid, default: 0] += 1
        }
    }
}
