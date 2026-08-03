import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let didOnboardKey = "hexad.didOnboard"
    /// How often to retry the event tap while Accessibility is missing. The tap cannot be
    /// created without it, the grant happens in another app, and nothing notifies us — so a
    /// poll is the only honest option.
    private static let tapRetryInterval: TimeInterval = 2

    private var statusItem: StatusItemController?
    private let store = WindowStore()
    private let overlay = StripOverlay()
    private var session: SwitcherSession?
    private var palette: PaletteController?
    private var grid: GridController?
    private var tap: HotkeyTap?
    private var tapRetry: Timer?
    private var observers: Set<AnyCancellable> = []
    private let trackpad = TrackpadGesture.shared

    private lazy var settingsWindow = AppWindow(title: "hexad Settings",
                                                size: NSSize(width: 720, height: 520)) {
        SettingsView()
    }

    /// Taller than it was: the tour gained a previews step with a live switch in it and a closing
    /// summary, and the window does not scroll — a step that runs off the bottom is a step nobody
    /// completes.
    private lazy var onboardingWindow: AppWindow = AppWindow(
        title: "Welcome to hexad",
        size: NSSize(width: 640, height: 660)
    ) { [weak self] in
        OnboardingView(onFinish: { self?.finishOnboarding() })
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reconcile our own claim before anything reads it. hexad never changes the flag on
        // another app's behalf — see SystemSwitcher.repairIfOrphaned.
        if SystemSwitcher.repairIfOrphaned() {
            NSLog("hexad: dropped a stale claim on ⌘Tab — macOS has it and we thought we did")
        }

        Preferences.shared.applyAppearance()

        statusItem = StatusItemController(onOpenSettings: { [weak self] in
            self?.openSettings()
        }, onOpenSwitcher: { [weak self] in
            self?.openCurrentMode()
        })
        // **N2** and **N5**: the menu presents them, the store owns them.
        statusItem?.onRecentlyClosed = { [weak self] in
            self?.store.closed.recent ?? []
        }
        statusItem?.onReopen = { [weak self] id in
            guard let self, let entry = self.store.closed.recent.first(where: { $0.id == id })
            else { return }
            self.store.closed.reopen(entry)
        }
        statusItem?.onSaveWorkspace = { [weak self] name in
            guard let self else { return }
            let workspace = WorkspaceStore.capture(self.store.allItems, named: name)
            var updated = Preferences.shared.workspaces
            updated.append(workspace)
            Preferences.shared.workspaces = Array(updated.suffix(WorkspaceStore.maxWorkspaces))
            RuntimeStatus.shared.trace("saved window set '\(name)' · \(workspace.summary)")
        }
        statusItem?.onRestoreWorkspace = { [weak self] id in
            guard let self,
                  let workspace = Preferences.shared.workspaces.first(where: { $0.id == id })
            else { return }
            let result = WorkspaceStore.restore(workspace, from: self.store.allItems,
                                                using: self.store)
            // A partial restore is reported rather than passed off as a success — you would
            // otherwise be looking at three windows believing you were looking at five.
            guard result.found < result.expected else { return }
            self.notifyPartialRestore(workspace, result: result)
        }
        applyMenuBarVisibility()
        // Every setting takes effect live — Phase 6's exit criterion. Hiding the icon while the
        // app keeps running is the one that most obviously must not wait for a relaunch.
        Preferences.shared.$hidesMenuBarIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] isHidden in
                self?.applyMenuBarVisibility(isHidden: isHidden)
            }
            .store(in: &observers)

        // One swipe is one whole interaction: it opens the switcher, scrubs the selection while
        // the fingers stay down, and commits when they lift. Three hooks rather than one trigger,
        // because "open" and "choose" are different questions.
        trackpad.onOpen = { [weak self] in
            DispatchQueue.main.async { self?.openCurrentMode() }
        }
        trackpad.onStep = { [weak self] delta in
            DispatchQueue.main.async { self?.stepCurrentMode(delta) }
        }
        trackpad.onCommit = { [weak self] in
            DispatchQueue.main.async { self?.commitCurrentMode() }
        }
        Preferences.shared.$isSwipeEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                self?.trackpad.start(enabled: isEnabled)
            }
            .store(in: &observers)

        // Switching modes while one is open would leave that overlay on screen with nothing
        // listening to it — a panel the user has to guess how to dismiss.
        Preferences.shared.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.closeAllOverlays()
            }
            .store(in: &observers)

        // Screen Recording is asked for at the moment the user turns previews on, and never
        // before — that is what makes "hexad asks for one permission" true rather than a claim
        // undermined on first launch. PLAN.md §2.
        Preferences.shared.$showsThumbnails
            .receive(on: RunLoop.main)
            .sink { isOn in
                if isOn {
                    if !Permissions.isScreenRecordingGranted {
                        Permissions.requestScreenRecording()
                    }
                } else {
                    Task { @MainActor in ThumbnailProvider.shared.invalidate() }
                }
            }
            .store(in: &observers)

        // Settings ▸ Setup can replay the welcome tour. The window lives here, so the request
        // arrives as a notification rather than the view reaching for the delegate.
        NotificationCenter.default.addObserver(forName: .hexadRunOnboarding,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.onboardingWindow.show()
        }

        // The Settings chord is read by the event tap, which knows nothing about windows.
        NotificationCenter.default.addObserver(forName: .hexadOpenSettings,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            NSApp.activate()
            self?.openSettings()
        }

        // An exclusion or a display filter changes what the list should contain, and the store
        // caches — so without this the change would not appear until the cache went stale on its
        // own, which reads as a setting that did nothing.
        NotificationCenter.default.addObserver(forName: .hexadWindowListChanged,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.store.rebuild()
        }

        // The tap reads a cached switcher state; this is what keeps it true.
        SystemSwitcher.startWatching()

        // Built once at launch, never on the hotkey. PLAN.md §11.
        overlay.prepare()
        store.start()

        palette = PaletteController(store: store)
        palette?.prepare()
        grid = GridController(store: store)
        grid?.prepare()

        let session = SwitcherSession(store: store, overlay: overlay)
        session.isSecondaryOpen = { [weak self] in
            switch Preferences.shared.effectiveMode {
            case .square: return false
            case .list: return self?.palette?.isOpen == true
            case .grid: return self?.grid?.isOpen == true
            }
        }
        // delta 0 opens; anything else moves the selection of the one already open. Never a
        // toggle — pressing the binding again must advance the switcher, not dismiss it.
        session.onSecondaryBinding = { [weak self] delta in
            guard let self else { return }
            switch Preferences.shared.effectiveMode {
            case .square: break
            case .list: delta == 0 ? self.palette?.open() : self.palette?.move(delta)
            case .grid: delta == 0 ? self.grid?.open() : self.grid?.move(delta)
            }
        }
        session.onSecondaryCommit = { [weak self] in
            guard let self else { return }
            switch Preferences.shared.effectiveMode {
            case .square: break
            case .list: if self.palette?.isOpen == true { self.palette?.close(commit: true) }
            case .grid: if self.grid?.isOpen == true { self.grid?.close(commit: true) }
            }
        }
        // Closing by any other route — Esc, Return, a click — must disarm the release-to-commit,
        // or the next modifier release commits a switcher that is no longer on screen.
        palette?.onClose = { [weak session] in session?.secondaryDidClose() }
        grid?.onClose = { [weak session] in session?.secondaryDidClose() }
        overlay.onChoose = { [weak session] index in session?.choose(index: index) }
        overlay.onHover = { [weak session] index in session?.hover(index: index) }
        overlay.onCloseWindow = { [weak session] index in session?.closeWindow(at: index) }
        overlay.onMinimizeWindow = { [weak session] index in session?.minimizeWindow(at: index) }
        overlay.displayFilterFellBack = { [weak self] in
            self?.store.didFallBackFromDisplayFilter ?? false
        }
        self.session = session
        let tap = HotkeyTap { [weak session] type, event in
            session?.handle(type, event) ?? false
        }
        self.tap = tap
        startTapWhenPermitted()
        // **R4.** The hint shows for the first few launches and then never again. Counted down at
        // launch rather than per invocation: three *sessions* is a day or two of use, three
        // invocations is thirty seconds.
        if Preferences.shared.remainingHintSessions > 0 {
            Preferences.shared.remainingHintSessions -= 1
        }

        // **N9.** The count beside the menu bar glyph, kept current as the list changes.
        NotificationCenter.default.addObserver(forName: .hexadMenuBarChanged,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            self.statusItem?.setCount(Preferences.shared.showsMenuBarCount
                                      ? self.store.allItems.filter { !$0.isAppOnly }.count
                                      : nil)
        }

        // **R8.** Tracing is on by default while hexad is pre-release, so the log grows on every
        // rebuild — which is every two seconds. Trimmed once at launch rather than on every write:
        // checking a file's size before appending a line would cost more than the line.
        RuntimeStatus.shared.trimLogIfNeeded()
        RuntimeStatus.shared.writeToLog("launched")

        if !UserDefaults.standard.bool(forKey: Self.didOnboardKey) {
            onboardingWindow.show()
        } else if !RuntimeStatus.shared.isListening {
            // Onboarding is done, yet hexad cannot listen — the permission was revoked, or the
            // signature changed under an ad-hoc build and TCC quietly dropped the grant. Either
            // way the app is dead and the menu bar icon looks identical to a working one, so it
            // says so in its own window rather than waiting to be discovered.
            settingsWindow.show()
        }
    }

    // MARK: - Opening

    /// The one place a mode is opened from, so the menu bar, the trackpad swipe and the tap all
    /// land on the same behaviour. The strip is the exception: it is a held gesture driven by the
    /// event tap, and opening it from a click would show a strip nobody can cycle or release.
    func openCurrentMode() {
        switch Preferences.shared.effectiveMode {
        case .square:
            session?.openSticky()
        case .list:
            palette?.toggle()
        case .grid:
            grid?.toggle()
        }
    }

    /// Move the open switcher's selection, whichever mode is showing.
    private func stepCurrentMode(_ delta: Int) {
        switch Preferences.shared.effectiveMode {
        case .square: session?.stepFromGesture(delta)
        case .list: palette?.move(delta)
        case .grid: grid?.move(delta)
        }
    }

    /// Take whatever is selected — the fingers have left the trackpad.
    private func commitCurrentMode() {
        switch Preferences.shared.effectiveMode {
        case .square: session?.commitFromGesture()
        case .list: if palette?.isOpen == true { palette?.close(commit: true) }
        case .grid: if grid?.isOpen == true { grid?.close(commit: true) }
        }
    }

    private func closeAllOverlays() {
        overlay.hide()
        if palette?.isOpen == true { palette?.close(commit: false) }
        if grid?.isOpen == true { grid?.close(commit: false) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tapRetry?.invalidate()
        tap?.stop()
        trackpad.stop()
        store.stop()
        // Never leave ⌘Tab off behind us.
        if SystemSwitcher.state == .hexadOwnsCommandTab {
            SystemSwitcher.restore()
        }
    }

    // MARK: - Tap

    /// Starting the tap is not one call, because the permission it needs may arrive minutes
    /// later — in another app — while hexad sits in the menu bar looking fine and doing nothing.
    /// Retrying is what makes "grant it and it starts working" true instead of aspirational.
    private func startTapWhenPermitted() {
        if attemptTapStart() { return }

        tapRetry?.invalidate()
        tapRetry = Timer.scheduledTimer(withTimeInterval: Self.tapRetryInterval,
                                        repeats: true) { [weak self] timer in
            guard let self, self.attemptTapStart() else { return }
            timer.invalidate()
            self.tapRetry = nil
        }
    }

    @discardableResult
    private func attemptTapStart() -> Bool {
        guard Permissions.isAccessibilityGranted, tap?.start() == true else {
            let wasListening = RuntimeStatus.shared.isListening
            RuntimeStatus.shared.isListening = false
            if wasListening { RuntimeStatus.shared.writeToLog("tap stopped") }
            return false
        }
        store.rebuild()
        RuntimeStatus.shared.isListening = true
        RuntimeStatus.shared.writeToLog("tap started")
        return true
    }

    // MARK: - Windows

    private func applyMenuBarVisibility(isHidden: Bool? = nil) {
        let hidden = isHidden ?? Preferences.shared.hidesMenuBarIcon
        if hidden {
            statusItem?.remove()
        } else {
            statusItem?.install()
        }
    }

    /// Say so when a window set could only be partly restored.
    ///
    /// An alert rather than a silent partial: the whole value of a named set is trusting that it
    /// came back, and a set that quietly returns three of five windows teaches you not to trust
    /// it without ever telling you why.
    private func notifyPartialRestore(_ workspace: Workspace,
                                      result: (found: Int, expected: Int)) {
        let alert = NSAlert()
        alert.messageText = "\(workspace.name) is partly here"
        alert.informativeText = "\(result.found) of \(result.expected) windows are still open. "
            + "hexad raises windows; it cannot reopen ones that have been closed or quit."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    private func openSettings() {
        settingsWindow.show()
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.didOnboardKey)
        onboardingWindow.close()
        startTapWhenPermitted()
    }
}
