import AppKit

/// The menu bar presence — deliberately small.
///
/// hexad's product surface is a full-screen overlay on a keypress; the menu bar is a back door,
/// not the app. So this is a glyph and a short menu, never a panel, and it can be hidden
/// entirely. PLAN.md §6.
final class StatusItemController: NSObject {

    private var statusItem: NSStatusItem?
    private let onOpenSettings: () -> Void
    private let onOpenSwitcher: () -> Void
    /// The window store's knowledge, injected rather than reached for: the menu bar has no
    /// business owning a `WindowStore`, and two stores would mean two AX walks.
    var onRecentlyClosed: () -> [ClosedWindows.Entry] = { [] }
    var onReopen: (String) -> Void = { _ in }
    var onSaveWorkspace: (String) -> Void = { _ in }
    var onRestoreWorkspace: (String) -> Void = { _ in }

    init(onOpenSettings: @escaping () -> Void,
         onOpenSwitcher: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onOpenSwitcher = onOpenSwitcher
        super.init()
    }

    // MARK: - Reopen and window sets

    @objc private func reopenClosed(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onReopen(id)
    }

    @objc private func restoreWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onRestoreWorkspace(id)
    }

    @objc private func forgetWorkspaces() {
        Preferences.shared.workspaces = []
    }

    /// A one-field prompt rather than a window: naming a set is a single answer, and a whole
    /// window for one text field is the kind of ceremony that stops people using a feature.
    @objc private func saveWorkspace() {
        let alert = NSAlert()
        alert.messageText = "Save these windows as a set"
        alert.informativeText = "Restoring raises them again, in the same order. It cannot reopen "
            + "anything that has been closed or quit in the meantime."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Writing, Review, Morning…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSaveWorkspace(name.isEmpty ? "Untitled set" : name)
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The menu bar gives a glyph about 18pt and scales whatever it is handed.
        item.button?.image = Brand.mark(height: 17)
        item.button?.toolTip = "hexad"
        item.menu = buildMenu()
        statusItem = item
        setCount(count)
    }

    /// **N9.** The open-window count beside the glyph, or `nil` to show the glyph alone.
    ///
    /// Two things at once: it says how much is open without opening anything, and it is the
    /// cheapest possible proof that hexad is alive and still counting — a menu bar icon looks
    /// identical whether the app is working or wedged, which is the failure this whole family of
    /// "honesty features" exists to answer.
    func setCount(_ count: Int?) {
        self.count = count
        guard let button = statusItem?.button else { return }
        guard let count else {
            button.title = ""
            button.imagePosition = .imageOnly
            return
        }
        button.title = " \(count)"
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    /// Kept so a reinstall of the item — hiding and unhiding the icon — restores what was showing.
    private var count: Int?

    func remove() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    /// Rebuilt on open so the ⌘Tab row always shows current state rather than a cached one.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /// **N2.** Windows closed in the last half hour, offered back.
    ///
    /// The menu is the right home for this rather than the switcher: the switcher lists what is
    /// open, and mixing in what is *not* open would make the one list answer two questions. Only
    /// shown when there is something to offer — a permanently empty submenu is furniture.
    private func addReopenSection(to menu: NSMenu) {
        let entries = onRecentlyClosed()
        guard !entries.isEmpty else { return }

        let item = NSMenuItem(title: "Reopen", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "arrow.uturn.left",
                             accessibilityDescription: nil)
        let submenu = NSMenu()
        for (offset, entry) in entries.prefix(9).enumerated() {
            let row = NSMenuItem(title: entry.title,
                                 action: #selector(reopenClosed(_:)),
                                 keyEquivalent: "")
            row.target = self
            row.representedObject = entry.id
            row.image = entry.icon
            // The app name is the honest promise: reopening asks that *app* for a window, which
            // is not the same as resurrecting the exact window. See `ClosedWindows`.
            row.toolTip = "Ask \(entry.appName) to open a window"
            row.isEnabled = entry.bundleID != nil
            _ = offset
            submenu.addItem(row)
        }
        item.submenu = submenu
        menu.addItem(item)
    }

    /// **N5.** Named sets of windows, saved and restored from here.
    private func addWorkspaceSection(to menu: NSMenu) {
        let item = NSMenuItem(title: "Window sets", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "rectangle.3.group",
                             accessibilityDescription: nil)
        let submenu = NSMenu()

        let workspaces = Preferences.shared.workspaces
        for workspace in workspaces {
            let row = NSMenuItem(title: workspace.name,
                                 action: #selector(restoreWorkspace(_:)),
                                 keyEquivalent: "")
            row.target = self
            row.representedObject = workspace.id
            row.toolTip = workspace.summary
            submenu.addItem(row)
        }
        if !workspaces.isEmpty { submenu.addItem(.separator()) }

        let save = NSMenuItem(title: "Save the current windows…",
                              action: #selector(saveWorkspace), keyEquivalent: "")
        save.target = self
        save.isEnabled = workspaces.count < WorkspaceStore.maxWorkspaces
        submenu.addItem(save)

        if !workspaces.isEmpty {
            let forget = NSMenuItem(title: "Forget all sets",
                                    action: #selector(forgetWorkspaces), keyEquivalent: "")
            forget.target = self
            submenu.addItem(forget)
        }

        item.submenu = submenu
        menu.addItem(item)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Read the machine once, before drawing anything from it.
        //
        // The menu used to mix two sources: the ⌘Tab row read live state while the shortcut row
        // read the tap's cache. When those disagreed the menu contradicted itself in adjacent
        // lines — "Shortcut: ⌘Tab" directly above "System ⌘Tab: On — macOS handles ⌘Tab" — which
        // is worse than either answer alone, because it gives the user no way to tell which half
        // is lying. One read, one truth, every time the menu opens.
        SystemSwitcher.refreshCachedState()

        let mode = Preferences.shared.mode

        // Open the switcher, with its own chord shown where macOS shows shortcuts. One action,
        // at the top, doing the thing the app exists for.
        let open = NSMenuItem(title: "Open \(mode.label)",
                              action: #selector(openSwitcher), keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: mode.systemImage, accessibilityDescription: nil)
        applyShortcutLabel(to: open, Preferences.shared.primaryBinding)
        menu.addItem(open)

        // Switching mode is the setting people change most and the one that most needs no
        // window. A submenu keeps it one hop away without adding three rows to the menu.
        let modeItem = NSMenuItem(title: "Switcher style", action: nil, keyEquivalent: "")
        modeItem.image = NSImage(systemSymbolName: "square.on.square",
                                 accessibilityDescription: nil)
        let modeMenu = NSMenu()
        for candidate in SwitcherMode.allCases {
            let row = NSMenuItem(title: candidate.label,
                                 action: #selector(selectMode(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = candidate.rawValue
            row.state = candidate == mode ? .on : .off
            row.image = NSImage(systemSymbolName: candidate.systemImage,
                                accessibilityDescription: nil)
            modeMenu.addItem(row)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        addReopenSection(to: menu)
        addWorkspaceSection(to: menu)

        menu.addItem(.separator())

        // Only surfaced when something is actually wrong. A permanent "everything is fine" row
        // is noise that trains people to stop reading the menu.
        if !RuntimeStatus.shared.isListening {
            let warning = NSMenuItem(title: RuntimeStatus.shared.summary,
                                     action: #selector(openSettings), keyEquivalent: "")
            warning.target = self
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                    accessibilityDescription: nil)
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        // ⌘Tab: one row that states the situation and offers the matching action, rather than a
        // disabled caption plus a sometimes-present button.
        switch SystemSwitcher.state {
        case .systemOwnsCommandTab:
            let item = NSMenuItem(title: "Use ⌘Tab for hexad",
                                  action: #selector(disableSystemSwitcher), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
            menu.addItem(item)
        case .hexadOwnsCommandTab:
            let item = NSMenuItem(title: "Give ⌘Tab back to macOS",
                                  action: #selector(restoreSystemSwitcher), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "arrow.uturn.backward",
                                 accessibilityDescription: nil)
            menu.addItem(item)
        case .offButNotOurs:
            // Offered rather than done for you — hexad does not change a flag it did not set.
            let item = NSMenuItem(title: "Give ⌘Tab back to macOS",
                                  action: #selector(restoreSystemSwitcher), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "arrow.uturn.backward",
                                 accessibilityDescription: nil)
            menu.addItem(item)
        case .unsupported:
            break
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit hexad", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Show a binding in the menu's shortcut column when AppKit can render it, so it sits where
    /// every other Mac menu puts a shortcut instead of being spelled out in the title.
    private func applyShortcutLabel(to item: NSMenuItem, _ binding: KeyBinding) {
        guard binding.keyCode == Shortcut.Key.tab else { return }
        item.keyEquivalent = "\t"
        var modifiers: NSEvent.ModifierFlags = []
        if binding.flags.contains(.maskCommand) { modifiers.insert(.command) }
        if binding.flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if binding.flags.contains(.maskControl) { modifiers.insert(.control) }
        if binding.flags.contains(.maskShift) { modifiers.insert(.shift) }
        item.keyEquivalentModifierMask = modifiers
        // The menu must not actually claim the chord — the event tap owns it, and a live key
        // equivalent here would fire the menu item as well.
        item.isAlternate = false
        item.allowsKeyEquivalentWhenHidden = false
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = SwitcherMode(rawValue: raw) else { return }
        Preferences.shared.mode = mode
    }

    @objc private func disableSystemSwitcher() { SystemSwitcher.disable() }

    @objc private func restoreSystemSwitcher() { SystemSwitcher.restore() }
    @objc private func openSwitcher() { onOpenSwitcher() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }
}
