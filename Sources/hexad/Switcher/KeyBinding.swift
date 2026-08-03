import AppKit

/// One chord the user assigned to open hexad.
///
/// Stored as a virtual key code plus modifier flags rather than as a character, because key codes
/// are positional and layout-independent: Tab is 48 on a US, German or Dvorak keyboard, and a
/// binding recorded on one layout keeps working on another.
struct KeyBinding: Codable, Equatable, Identifiable {

    var keyCode: Int64
    /// `CGEventFlags` raw value, already narrowed to the modifiers hexad cares about.
    var modifiers: UInt64

    var id: String { "\(modifiers).\(keyCode)" }

    /// The modifiers a binding may be built from. Caps Lock and the numeric-pad flag arrive on
    /// ordinary events and would make an exact comparison fail for no reason.
    static let relevantMask: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift,
    ]

    var flags: CGEventFlags {
        CGEventFlags(rawValue: modifiers).intersection(Self.relevantMask)
    }

    // MARK: - Defaults

    static let commandTab = KeyBinding(keyCode: Shortcut.Key.tab,
                                       modifiers: CGEventFlags.maskCommand.rawValue)
    static let optionTab = KeyBinding(keyCode: Shortcut.Key.tab,
                                      modifiers: CGEventFlags.maskAlternate.rawValue)
    static let optionSpace = KeyBinding(keyCode: Shortcut.Key.space,
                                        modifiers: CGEventFlags.maskAlternate.rawValue)
    /// The third shipped binding. Free — macOS uses ⌃Tab only inside apps with tab bars, and it
    /// works whether or not the ⌘Tab takeover has happened.
    static let controlTab = KeyBinding(keyCode: Shortcut.Key.tab,
                                       modifiers: CGEventFlags.maskControl.rawValue)

    // MARK: - Matching

    /// Shift is allowed on top of any binding and means "cycle backwards", so it never
    /// disqualifies a match. Any *other* extra modifier does: ⌃⌘Tab is not ⌘Tab, and firing on
    /// it would steal a chord that belongs to whatever the user is actually working in.
    func matches(keyCode: Int64, flags eventFlags: CGEventFlags) -> Bool {
        guard keyCode == self.keyCode else { return false }
        let held = eventFlags.intersection(Self.relevantMask)
        let required = flags
        guard held.isSuperset(of: required) else { return false }
        let permitted = required.union(.maskShift)
        return permitted.isSuperset(of: held)
    }

    /// The modifier whose release commits the selection, for modes that cycle while held.
    ///
    /// `nil` when the binding has no modifier at all — F13 on its own, say. There is nothing to
    /// release then, so the mode has to be a toggle rather than a hold, and the caller decides
    /// that rather than waiting forever for a key-up that cannot come.
    var holdModifier: CGEventFlags? {
        let held = flags
        // Ordered by how a chord is normally read, so ⌥⌘Tab holds on Command.
        for candidate: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate] {
            if held.contains(candidate) { return candidate }
        }
        return held.contains(.maskShift) ? .maskShift : nil
    }

    var isHoldable: Bool { holdModifier != nil }

    /// The modifier that turns a letter into an action rather than a search character, while this
    /// binding is being held.
    ///
    /// Square holds a modifier for the whole session, so ⌘W *cannot* mean "close" there: with
    /// ⌘Tab held, ⌘ is already down and the W is indistinguishable from typing one. The action
    /// key therefore carries a modifier the binding does not — ⌥W under ⌘Tab, ⌘W under ⌥Tab —
    /// which is the only rule that works for every binding a user might record.
    var actionModifier: CGEventFlags {
        let held = flags
        for candidate: CGEventFlags in [.maskCommand, .maskAlternate, .maskControl] {
            if !held.contains(candidate) { return candidate }
        }
        return .maskControl
    }

    /// How that modifier is written on a keycap — "⌥" for ⌘Tab, "⌘" for ⌥Tab.
    var actionModifierLabel: String {
        let modifier = actionModifier
        if modifier.contains(.maskCommand) { return "⌘" }
        if modifier.contains(.maskAlternate) { return "⌥" }
        return "⌃"
    }

    func isHeld(in eventFlags: CGEventFlags) -> Bool {
        guard let holdModifier else { return false }
        return eventFlags.contains(holdModifier)
    }

    // MARK: - Recording

    /// Built from a real keystroke, which is the only way a binding is ever created.
    init?(event: NSEvent) {
        var flags: CGEventFlags = []
        if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
        if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }

        let code = Int64(event.keyCode)
        // A bare letter would swallow that letter everywhere, in every app, forever. Function
        // keys are the documented exception because they are not typing keys.
        if flags.isEmpty && !KeyName.isFunctionKey(code) { return nil }

        self.init(keyCode: code, modifiers: flags.rawValue)
    }

    init(keyCode: Int64, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // MARK: - Display

    /// In the order macOS writes them in menus — ⌃⌥⇧⌘ — so a hexad chord reads the same as a
    /// system one.
    var label: String {
        var text = ""
        let held = flags
        if held.contains(.maskControl) { text += "⌃" }
        if held.contains(.maskAlternate) { text += "⌥" }
        if held.contains(.maskShift) { text += "⇧" }
        if held.contains(.maskCommand) { text += "⌘" }
        return text + KeyName.of(keyCode)
    }
}

/// Virtual key code to the glyph a Mac user expects to see on a keycap.
///
/// Only the keys someone would plausibly bind. Anything unlisted shows its code rather than a
/// wrong name — a binding labelled "Key 92" is odd but honest, and still works.
enum KeyName {

    private static let names: [Int64: String] = [
        48: "Tab", 49: "Space", 36: "↩", 53: "Esc", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        116: "Page Up", 121: "Page Down", 115: "Home", 119: "End",
        50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 42: "\\",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
        35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
        13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    private static let functionKeys: Set<Int64> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90,
    ]

    static func of(_ keyCode: Int64) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    static func isFunctionKey(_ keyCode: Int64) -> Bool {
        functionKeys.contains(keyCode)
    }

    /// The character this key contributes to a search query, or `nil` if it is not a typing key.
    ///
    /// Reuses the keycap table rather than translating through the current layout: a filter is
    /// matched case-insensitively against window titles, so "the letter on the key" is exactly
    /// what is wanted and one lookup beats a `UCKeyTranslate` dance.
    static func typedCharacter(_ keyCode: Int64) -> Character? {
        guard let name = names[keyCode], name.count == 1,
              let character = name.first,
              character.isLetter || character.isNumber
        else { return nil }
        return Character(character.lowercased())
    }
}

extension KeyName {
    /// The number a top-row digit key types, or nil for anything else. Keypad digits are
    /// deliberately excluded: a numeric keypad is for numbers, not for jumping the switcher.
    static func digit(_ keyCode: Int64) -> Int? {
        switch keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
    }
}
