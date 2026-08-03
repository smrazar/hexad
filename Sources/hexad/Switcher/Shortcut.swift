import AppKit

/// The key that opens the strip.
///
/// hexad wants ⌘Tab, but it only gets ⌘Tab once the user has turned the macOS switcher off —
/// otherwise both would fire and the system one wins. Until then it runs on ⌥Tab and says so,
/// which is also the honest answer when someone declines during onboarding. PLAN.md §7.
struct Shortcut: Equatable {

    /// Virtual key codes. These are positional and layout-independent, which is the whole
    /// reason to use them over characters — Tab is 48 on every keyboard layout.
    enum Key {
        static let tab: Int64 = 48
        static let escape: Int64 = 53
        static let delete: Int64 = 51
        static let space: Int64 = 49
        static let returnKey: Int64 = 36
        static let leftArrow: Int64 = 123
        static let rightArrow: Int64 = 124
        static let downArrow: Int64 = 125
        static let upArrow: Int64 = 126
        static let w: Int64 = 13
        static let m: Int64 = 46
        static let q: Int64 = 12
        static let h: Int64 = 4
        static let n: Int64 = 45
        static let s: Int64 = 1
        static let d: Int64 = 2
        static let p: Int64 = 35
        static let t: Int64 = 17
        static let three: Int64 = 20
        static let four: Int64 = 21
        static let five: Int64 = 23
        /// The key above Tab. Paired with the binding's own modifier it steps backwards, which is
        /// the convention macOS itself uses for "the other direction" within an app.
        static let grave: Int64 = 50
    }

    let modifier: CGEventFlags
    let keyCode: Int64
    let label: String

    static let commandTab = Shortcut(modifier: .maskCommand, keyCode: Key.tab, label: "⌘Tab")
    static let optionTab = Shortcut(modifier: .maskAlternate, keyCode: Key.tab, label: "⌥Tab")

    /// The palette and the grid never contend with a system shortcut, so unlike the strip they
    /// are fixed rather than negotiated.
    static let palette = Shortcut(modifier: .maskAlternate, keyCode: Key.space, label: "⌥Space")
    static let grid = Shortcut(modifier: .maskAlternate, keyCode: Key.tab, label: "⌥⇧Tab")

    /// hexad takes ⌘Tab only when it actually owns it.
    ///
    /// Reads the **cached** state, because this is evaluated inside the event tap on every
    /// Tab keypress and asking WindowServer there can cost 21ms — see SystemSwitcher.state.
    static var active: Shortcut {
        SystemSwitcher.cachedState == .hexadOwnsCommandTab ? .commandTab : .optionTab
    }

    func isHeld(in flags: CGEventFlags) -> Bool {
        flags.contains(modifier)
    }
}
