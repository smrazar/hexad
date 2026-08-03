import SwiftUI

/// Shortcuts — every way of opening hexad, and nothing else.
///
/// The ⌘Tab takeover lives in Setup, because it is done once. What it does *not* do is send you
/// there: a ⌘Tab binding that cannot fire yet now carries the button to fix it, in its own row.
/// The previous copy said "turn it off above" and the control was not above — it was in another
/// pane — which is exactly the kind of instruction this pass exists to delete.
struct ShortcutsPane: View {

    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var trackpad: TrackpadGesture

    var body: some View {
        bindingsSection

        SettingsSection(title: "Other keys", systemImage: "gear.badge") {
            SettingsRow(title: "Open Settings",
                        description: preferences.settingsBinding == nil
                            ? "Unbound. Worth setting if you ever hide the menu bar icon."
                            : "Opens this window from anywhere.",
                        systemImage: "gearshape",
                        showsDivider: false) {
                ShortcutRecorder(binding: preferences.settingsBinding,
                                 onRecord: { preferences.settingsBinding = $0 },
                                 onClear: preferences.settingsBinding == nil
                                     ? nil
                                     : { preferences.settingsBinding = nil })
            }
        }

        SettingsSection(title: "While the switcher is open", systemImage: "hand.tap") {
            SettingsRow(title: "Actions",
                        description: actionsDescription,
                        systemImage: "command",
                        showsDivider: false) {
                EmptyView()
            }
        }

        SettingsSection(title: "Trackpad", systemImage: "hand.draw") {
            SettingsRow(title: "Three-finger swipe",
                        description: "Swipe left or right with three fingers to open hexad, keep "
                                   + "swiping to move the selection, and lift to switch.",
                        systemImage: "hand.point.up.left") {
                Toggle("", isOn: $preferences.isSwipeEnabled)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Three-finger swipe")
            }

            SettingsRow(title: "Scroll to move",
                        description: "Two-finger scroll moves the selection while the switcher "
                                   + "is open.",
                        systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
                Toggle("", isOn: $preferences.scrollSteps)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Scroll to move")
            }

            SettingsRow(title: "Gesture check",
                        description: swipeDiagnosis,
                        systemImage: "waveform.path.ecg",
                        showsDivider: false) {
                StatusPill(text: model.lastSwipeSummary, isGood: model.hasSeenSwipe)
            }
        }
    }

    // MARK: - Bindings

    private var bindingsSection: some View {
        SettingsSection(title: "Opens hexad", systemImage: "keyboard") {
            ForEach(Array(preferences.bindings.enumerated()), id: \.offset) { index, binding in
                SettingsRow(title: index == 0 ? "Shortcut" : "Also",
                            description: describe(binding),
                            systemImage: index == 0 ? "command" : "plus.circle",
                            showsDivider: true) {
                    HStack(spacing: Theme.Space.s8) {
                        // The fix for "this chord cannot fire yet", in the row that says so.
                        if needsSwitcherHandover(binding) {
                            Button("Turn ⌘Tab over") { model.disableSystemSwitcher() }
                                .buttonStyle(.hexadPrimary)
                        }
                        ShortcutRecorder(binding: binding,
                                         onRecord: { preferences.setBinding($0, at: index) },
                                         onClear: preferences.bindings.count > 1
                                             ? { preferences.removeBinding(at: index) }
                                             : nil)
                    }
                }
            }

            if preferences.bindings.count < Preferences.maxBindings {
                SettingsRow(title: "Add a shortcut",
                            description: "Up to \(Preferences.maxBindings) chords can open hexad.",
                            systemImage: "plus",
                            showsDivider: false) {
                    ShortcutRecorder(binding: nil,
                                     onRecord: { preferences.addBinding($0) })
                }
            } else {
                SettingsRow(title: "That is the limit",
                            description: "Remove one to bind another. Three ways in is plenty.",
                            systemImage: "checkmark.circle",
                            showsDivider: false) {
                    EmptyView()
                }
            }
        }
    }

    /// True when this chord is ⌘Tab and macOS has not handed it over yet.
    private func needsSwitcherHandover(_ binding: KeyBinding) -> Bool {
        binding.keyCode == Shortcut.Key.tab
            && binding.flags.contains(.maskCommand)
            && model.switcherState != .hexadOwnsCommandTab
    }

    /// Says what each chord will actually do right now, which is not always what it looks like:
    /// ⌘Tab is inert until the macOS switcher is off, a chord with no modifier cannot be held so
    /// it opens a switcher that waits for Return, and a chord that already means something else
    /// will stop meaning it.
    private func describe(_ binding: KeyBinding) -> String {
        if needsSwitcherHandover(binding) {
            return "Inactive — macOS still owns ⌘Tab."
        }
        if let warning = ShortcutConflicts.warning(for: binding) {
            return warning
        }
        if preferences.mode.isHeldToCycle && !binding.isHoldable {
            return "No modifier to hold, so the switcher stays up until you press Return."
        }
        return "Opens the \(preferences.mode.label.lowercased())."
    }

    /// The action keys depend on the binding: Square holds a modifier for the whole session, so
    /// ⌘W cannot mean "close" there. Saying which modifier applies beats saying "⌘W" and being
    /// wrong for the binding the user actually chose.
    private var actionsDescription: String {
        let modifier = preferences.primaryBinding.actionModifierLabel
        if preferences.mode.isHeldToCycle {
            return "\(modifier)W close · \(modifier)M minimise · \(modifier)H hide · "
                 + "\(modifier)Q quit · ⌘1…⌘9 jump · middle-click closes."
        }
        return "⌘W close · ⌘M minimise · ⌘H hide · ⌘Q quit · middle-click closes."
    }

    private var swipeDiagnosis: String {
        if !preferences.isSwipeEnabled {
            return "Switch it on above, then swipe to test it."
        }
        if model.hasSeenSwipe {
            return "Swipes are reaching hexad."
        }
        return "If nothing is seen, macOS is using three fingers for Mission Control."
    }
}
