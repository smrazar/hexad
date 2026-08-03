import AppKit

/// Control over the macOS ⌘Tab app switcher.
///
/// macOS exposes no public API and no System Settings path for this — the only route is a private
/// SkyLight call. hexad never makes it silently: it is an onboarding step with a button, and a
/// visible setting with a Restore beside it.
///
/// Symbols are resolved with dlopen/dlsym rather than linked, so an OS that drops them degrades
/// to a clear message instead of failing to launch.
///
/// See docs/BUGS.md B1 — an orphaned flag left by an uninstalled app is an observed failure on
/// this machine, not a hypothetical.
enum SystemSwitcher {

    /// Symbolic hotkey IDs. 71 is ⌘Tab, 72 is ⌘⇧Tab. Established by observing a running
    /// switcher hold 71 disabled, not by reading anyone's source.
    private static let idCommandTab: Int32 = 71
    private static let idCommandShiftTab: Int32 = 72

    /// Whether hexad believes it is the one holding the switcher off.
    private static let ownershipKey = "hexad.disabledSystemSwitcher"

    // MARK: - Private symbols

    private typealias SetEnabledFn = @convention(c) (Int32, Bool) -> Int32
    private typealias IsEnabledFn = @convention(c) (Int32) -> Bool

    private struct Symbols {
        let setEnabled: SetEnabledFn
        let isEnabled: IsEnabledFn
    }

    private static let symbols: Symbols? = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY),
              let set = dlsym(handle, "CGSSetSymbolicHotKeyEnabled"),
              let get = dlsym(handle, "CGSIsSymbolicHotKeyEnabled")
        else { return nil }
        return Symbols(setEnabled: unsafeBitCast(set, to: SetEnabledFn.self),
                       isEnabled: unsafeBitCast(get, to: IsEnabledFn.self))
    }()

    /// False on an OS that no longer offers the call. The UI must say so rather than
    /// offering a button that silently does nothing.
    static var isSupported: Bool { symbols != nil }

    // MARK: - State

    enum State: Equatable {
        /// The macOS switcher is active. ⌘Tab belongs to the system.
        case systemOwnsCommandTab
        /// The macOS switcher is off and hexad turned it off.
        case hexadOwnsCommandTab
        /// The macOS switcher is off but hexad did not do it — another app, or an orphan.
        case offButNotOurs
        /// The private call is unavailable on this OS.
        case unsupported
    }

    /// Asks WindowServer. **Never call this from the event tap.** Measured on macOS 26.5.2:
    /// p50 37µs, p99 362µs, worst case 21ms — twenty-one times the entire 1ms tap budget, and
    /// a tap that overruns is disabled by the system without an error anywhere. That is the
    /// "it just stops working after a while" failure this app exists to avoid.
    static var state: State {
        guard let symbols else { return .unsupported }
        if symbols.isEnabled(idCommandTab) { return .systemOwnsCommandTab }
        return weClaimOwnership ? .hexadOwnsCommandTab : .offButNotOurs
    }

    /// What the hot path reads instead. Updated only from places that can afford to block.
    private(set) static var cachedState: State = .unsupported

    @discardableResult
    static func refreshCachedState() -> State {
        cachedState = state
        return cachedState
    }

    /// The flag can be changed by any other app that reaches for the same private call, so a
    /// cache written only by hexad's own actions would drift. Polling is honest here: 37µs every
    /// few seconds, off the keyboard path, against no notification existing.
    static func startWatching(interval: TimeInterval = 5) {
        refreshCachedState()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            refreshCachedState()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static var weClaimOwnership: Bool {
        get { UserDefaults.standard.bool(forKey: ownershipKey) }
        set { UserDefaults.standard.set(newValue, forKey: ownershipKey) }
    }

    // MARK: - Actions

    /// Turn the macOS switcher off so hexad can own ⌘Tab. Only ever called from an explicit
    /// user action — onboarding or the settings toggle.
    @discardableResult
    static func disable() -> Bool {
        guard let symbols else { return false }
        _ = symbols.setEnabled(idCommandTab, false)
        _ = symbols.setEnabled(idCommandShiftTab, false)
        weClaimOwnership = true
        refreshCachedState()
        return !symbols.isEnabled(idCommandTab)
    }

    /// Give ⌘Tab back to macOS. Called from the settings Restore button, on quit, and when
    /// the user declines during onboarding.
    @discardableResult
    static func restore() -> Bool {
        guard let symbols else { return false }
        _ = symbols.setEnabled(idCommandTab, true)
        _ = symbols.setEnabled(idCommandShiftTab, true)
        weClaimOwnership = false
        refreshCachedState()
        return symbols.isEnabled(idCommandTab)
    }

    /// Reconcile hexad's own claim at launch. **It never changes the flag on someone else's
    /// behalf.**
    ///
    /// There is exactly one case worth repairing automatically: hexad believes it turned ⌘Tab off
    /// while macOS plainly has it on, which is what a crash between disabling and restoring leaves
    /// behind. Left alone, hexad binds to a shortcut the system switcher is answering.
    ///
    /// The mirror case — the flag is off and hexad did not turn it off — is deliberately **not**
    /// repaired. An earlier version restored it, on the theory that it must be an orphan left by an
    /// uninstalled app (docs/BUGS.md B1). That theory cannot be told apart from "another switcher
    /// is running and using it", and acting on it took ⌘Tab away from an app the user had chosen
    /// to run. Trying to tell them apart meant hardcoding a list of competitors' names, which is a
    /// list that is only as good as the imagination that wrote it and does not belong in this app.
    ///
    /// So an orphaned flag is surfaced rather than silently fixed: Settings and the menu both offer
    /// Restore whenever ⌘Tab is off and hexad is not the one holding it. One click, visible,
    /// and never a surprise.
    @discardableResult
    static func repairIfOrphaned() -> Bool {
        guard state == .systemOwnsCommandTab && weClaimOwnership else { return false }
        weClaimOwnership = false
        refreshCachedState()
        return true
    }

    /// Plain words for the settings row. Never a raw boolean in the UI.
    static var statusDescription: String {
        switch state {
        case .systemOwnsCommandTab: return "On — macOS handles ⌘Tab"
        case .hexadOwnsCommandTab: return "Off — hexad handles ⌘Tab"
        case .offButNotOurs: return "Off — another app is using it"
        case .unsupported: return "Unavailable on this version of macOS"
        }
    }
}
