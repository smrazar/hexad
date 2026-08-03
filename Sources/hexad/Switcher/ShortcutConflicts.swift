import AppKit

/// Chords that already mean something, so binding one can be warned about rather than discovered.
///
/// hexad's event tap sits ahead of nearly everything, so a binding it claims genuinely stops
/// working elsewhere — bind ⌘Q and the user cannot quit any app. Nothing here is *blocked*: the
/// machine belongs to the user and a switcher refusing a chord it dislikes is worse than one that
/// says what will happen. The two rules that *are* enforced live in `KeyBinding.init(event:)` and
/// are of a different kind — a bare letter, and removing the last binding, both lock the user out.
///
/// ponytail: a static table, not a read of the system's symbolic-hotkey plist. The plist is
/// undocumented, per-user, and would need parsing on every keystroke recorded; this covers what
/// people actually reach for and costs nothing.
enum ShortcutConflicts {

    struct Conflict {
        /// What already owns the chord, in words that name the consequence.
        let owner: String
        /// True when hexad taking it would break something the user needs elsewhere, as opposed
        /// to merely overlapping with something niche.
        let isSevere: Bool
    }

    private struct Entry {
        let keyCode: Int64
        let flags: CGEventFlags
        let owner: String
        let isSevere: Bool
    }

    private static let known: [Entry] = [
        // The ones that would take away an action every app depends on.
        Entry(keyCode: Shortcut.Key.q, flags: .maskCommand,
              owner: "Quit, in every app", isSevere: true),
        Entry(keyCode: Shortcut.Key.w, flags: .maskCommand,
              owner: "Close window, in every app", isSevere: true),
        Entry(keyCode: Shortcut.Key.space, flags: .maskCommand,
              owner: "Spotlight", isSevere: true),
        Entry(keyCode: Shortcut.Key.h, flags: .maskCommand,
              owner: "Hide, in every app", isSevere: true),
        Entry(keyCode: Shortcut.Key.m, flags: .maskCommand,
              owner: "Minimise, in every app", isSevere: true),
        Entry(keyCode: Shortcut.Key.n, flags: .maskCommand,
              owner: "New, in every app", isSevere: true),
        Entry(keyCode: Shortcut.Key.s, flags: .maskCommand,
              owner: "Save, in every app", isSevere: true),

        // System shortcuts. Losing these is annoying rather than crippling.
        Entry(keyCode: Shortcut.Key.space, flags: [.maskCommand, .maskAlternate],
              owner: "Finder search", isSevere: false),
        Entry(keyCode: Shortcut.Key.escape, flags: [.maskCommand, .maskAlternate],
              owner: "Force Quit", isSevere: true),
        Entry(keyCode: Shortcut.Key.d, flags: [.maskCommand, .maskAlternate],
              owner: "Show or hide the Dock", isSevere: false),
        Entry(keyCode: Shortcut.Key.three, flags: [.maskCommand, .maskShift],
              owner: "Screenshot the screen", isSevere: false),
        Entry(keyCode: Shortcut.Key.four, flags: [.maskCommand, .maskShift],
              owner: "Screenshot a selection", isSevere: false),
        Entry(keyCode: Shortcut.Key.five, flags: [.maskCommand, .maskShift],
              owner: "Screenshot and recording tools", isSevere: false),
        Entry(keyCode: Shortcut.Key.grave, flags: .maskCommand,
              owner: "Cycle windows within an app", isSevere: false),
    ]

    /// What else this chord means, or `nil` if it is free.
    ///
    /// ⌘Tab is deliberately absent: it is the chord hexad is *for*, and the Setup pane already
    /// says in full whether macOS or hexad currently owns it.
    static func conflict(for binding: KeyBinding) -> Conflict? {
        let held = binding.flags
        guard let entry = known.first(where: {
            $0.keyCode == binding.keyCode && $0.flags == held
        }) else { return nil }
        return Conflict(owner: entry.owner, isSevere: entry.isSevere)
    }

    /// A sentence for the settings row, or `nil` when there is nothing to say.
    static func warning(for binding: KeyBinding) -> String? {
        guard let conflict = conflict(for: binding) else { return nil }
        return conflict.isSevere
            ? "\(binding.label) is \(conflict.owner). hexad will take it."
            : "Also \(conflict.owner)."
    }
}
