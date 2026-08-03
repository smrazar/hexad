import SwiftUI

/// Setup — everything hexad needs before it can work, in one place.
///
/// These rows used to be scattered: Accessibility sat in General, the ⌘Tab takeover sat in
/// Shortcuts beside the chord list, and Screen Recording only appeared under Appearance next to
/// the previews toggle that needs it. That is three panes to visit to answer one question — "is
/// this app actually set up?" — and the answer to that question is the difference between hexad
/// working and hexad looking broken. So it is a pane of its own, first in the sidebar.
struct SetupPane: View {

    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        SettingsSection(title: "Permissions", systemImage: "lock.shield") {
            SettingsRow(title: "Accessibility",
                        description: "Required. Lets hexad list windows and raise the one you pick.",
                        systemImage: "accessibility") {
                HStack(spacing: Theme.Space.s8) {
                    StatusPill(text: model.isAccessibilityGranted ? "Granted" : "Not granted",
                               isGood: model.isAccessibilityGranted)
                    if !model.isAccessibilityGranted {
                        Button("Grant…") { model.requestAccessibility() }
                            .buttonStyle(.hexadPrimary)
                        Button("Open System Settings") {
                            Permissions.openAccessibilitySettings()
                        }
                        .buttonStyle(.hexadSecondary)
                    }
                }
            }

            SettingsRow(title: "Screen Recording",
                        description: "Optional. Only for window previews — hexad never asks "
                                   + "until you turn them on.",
                        systemImage: "rectangle.inset.filled.badge.record",
                        showsDivider: false) {
                HStack(spacing: Theme.Space.s8) {
                    StatusPill(text: model.isScreenRecordingGranted ? "Granted" : "Not granted",
                               isGood: model.isScreenRecordingGranted)
                    if !model.isScreenRecordingGranted {
                        Button("Open System Settings") {
                            Permissions.openScreenRecordingSettings()
                        }
                        .buttonStyle(.hexadSecondary)
                    }
                }
            }
        }

        SettingsSection(title: "The ⌘Tab key", systemImage: "command") {
            SettingsRow(title: "System switcher",
                        description: systemSwitcherDescription,
                        systemImage: "square.stack",
                        showsDivider: false) {
                HStack(spacing: Theme.Space.s8) {
                    StatusPill(text: switcherPill,
                               isGood: model.switcherState == .hexadOwnsCommandTab)
                    switch model.switcherState {
                    case .systemOwnsCommandTab:
                        Button("Turn it off") { model.disableSystemSwitcher() }
                            .buttonStyle(.hexadPrimary)
                    case .hexadOwnsCommandTab:
                        Button("Restore") { model.restoreSystemSwitcher() }
                            .buttonStyle(.hexadSecondary)
                    case .offButNotOurs:
                        // ⌘Tab is already off and hexad did not do it — most often its own record
                        // was wiped by a fresh install while WindowServer kept the flag. Claiming
                        // it is one call and makes the two agree again.
                        Button("Claim it") { model.disableSystemSwitcher() }
                            .buttonStyle(.hexadPrimary)
                        Button("Give it back") { model.restoreSystemSwitcher() }
                            .buttonStyle(.hexadSecondary)
                    case .unsupported:
                        EmptyView()
                    }
                }
            }
        }

        SettingsSection(title: "Status", systemImage: "waveform.path.ecg") {
            SettingsRow(title: "Listening",
                        description: model.listeningSummary,
                        systemImage: "dot.radiowaves.left.and.right",
                        showsDivider: false) {
                StatusPill(text: model.isListening ? "Yes" : "No", isGood: model.isListening)
            }
        }

        // "How the app itself runs" was a pane of its own called General, holding two switches.
        // A pane per pair of switches is why changing anything meant a tour of the sidebar.
        SettingsSection(title: "The app", systemImage: "gearshape") {
            SettingsRow(title: "Launch at login",
                        description: "Start hexad when you log in.",
                        systemImage: "power") {
                Toggle("", isOn: $preferences.launchesAtLogin)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Launch at login")
            }

            SettingsRow(title: "Show the window count in the menu bar",
                        description: "\"14\" beside the icon — how much is open, and proof hexad "
                                   + "is still counting.",
                        systemImage: "number.square") {
                Toggle("", isOn: $preferences.showsMenuBarCount)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .disabled(preferences.hidesMenuBarIcon)
                    .accessibilityLabel("Show the window count in the menu bar")
            }

            SettingsRow(title: "Hide the menu bar icon",
                        description: menuBarDescription,
                        systemImage: "menubar.rectangle",
                        showsDivider: preferences.hidesMenuBarIcon) {
                Toggle("", isOn: $preferences.hidesMenuBarIcon)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Hide the menu bar icon")
            }

            // Hiding the icon used to make Settings unreachable without relaunching — a switch
            // that turned off the only route back to the switch. The fix belongs in the same row
            // group as the cause, not in a different pane.
            if preferences.hidesMenuBarIcon {
                SettingsRow(title: "Shortcut for Settings",
                            description: preferences.settingsBinding == nil
                                ? "Nothing is bound. Without the menu bar icon, only a relaunch "
                                + "reopens this window."
                                : "Opens this window from anywhere.",
                            systemImage: "gear.badge",
                            showsDivider: false) {
                    ShortcutRecorder(binding: preferences.settingsBinding,
                                     onRecord: { preferences.settingsBinding = $0 },
                                     onClear: preferences.settingsBinding == nil
                                         ? nil
                                         : { preferences.settingsBinding = nil })
                }
            }
        }

        SettingsSection(title: "Welcome tour", systemImage: "sparkles") {
            SettingsRow(title: "Run setup again",
                        description: "Walks through the ⌘Tab takeover, the permission and the "
                                   + "switcher style, exactly as on a first launch.",
                        systemImage: "arrow.clockwise",
                        showsDivider: false) {
                Button("Run setup") {
                    NotificationCenter.default.post(name: .hexadRunOnboarding, object: nil)
                }
                .buttonStyle(.hexadSecondary)
            }
        }
    }

    private var menuBarDescription: String {
        guard preferences.hidesMenuBarIcon else {
            return "hexad keeps running either way. The icon is how you reach Settings."
        }
        return preferences.settingsBinding == nil
            ? "The icon is hidden. Bind a shortcut below, or Settings needs a relaunch."
            : "The icon is hidden. \(preferences.settingsBinding?.label ?? "") reopens Settings."
    }

    private var switcherPill: String {
        switch model.switcherState {
        case .hexadOwnsCommandTab: return "hexad has ⌘Tab"
        case .systemOwnsCommandTab: return "macOS has ⌘Tab"
        case .offButNotOurs: return "⌘Tab is off"
        case .unsupported: return "Unavailable"
        }
    }

    /// Says what the state *means*, not what it is — the pill already says what it is.
    private var systemSwitcherDescription: String {
        switch model.switcherState {
        case .hexadOwnsCommandTab:
            return "macOS has handed ⌘Tab over. hexad restores it automatically when it quits."
        case .systemOwnsCommandTab:
            return "macOS still answers ⌘Tab, so a ⌘Tab binding cannot fire until this is off."
        case .offButNotOurs:
            return "⌘Tab is already off, but hexad has no record of turning it off — usually a fresh install. Claim it so the two agree."
        case .unsupported:
            return "This version of macOS does not expose the switcher flag."
        }
    }
}

extension Notification.Name {
    /// Posted by Settings ▸ Setup. The delegate owns the onboarding window, not this view.
    static let hexadRunOnboarding = Notification.Name("hexad.runOnboarding")

    /// A setting changed what the window list should contain — an exclusion, a display filter.
    /// The store caches, so nothing would take effect until the cache went stale on its own.
    static let hexadWindowListChanged = Notification.Name("hexad.windowListChanged")

    /// The Settings shortcut fired. The delegate owns the window; the event tap only sees keys.
    static let hexadOpenSettings = Notification.Name("hexad.openSettings")

    /// Something the menu bar item displays has changed — the count setting, or the count itself.
    static let hexadMenuBarChanged = Notification.Name("hexad.menuBarChanged")
}
