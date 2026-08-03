import SwiftUI

/// First launch, five steps: take ⌘Tab, get Accessibility, choose a switcher, decide about
/// previews, then a summary of what was actually set up.
///
/// Built as §11's permission screen rather than as a wall of text with two system buttons: an app
/// glyph, one plain-language reason, contextual icon rows, and a single primary action per step.
/// The ⌘Tab takeover is the first thing hexad asks about and declining is a real answer — the app
/// falls back to ⌥Tab and says so, rather than nagging. Turning off a system shortcut behind the
/// user's back is exactly the failure in docs/BUGS.md B1, seen from the other side.
///
/// **Previews and Screen Recording are asked here, not discovered in Settings.** They were left
/// out on the theory that a second permission on first launch is what gets an app denied — but
/// leaving them out did not remove the decision, it only moved it somewhere the user had to find.
/// The honest version is to ask, explain that it is optional, and show the answer as a switch the
/// user can flip on the spot rather than a promise about a default: the last
/// step then says what hexad ended up with, so nobody finishes setup unsure whether it worked.
struct OnboardingView: View {

    let onFinish: () -> Void

    @State private var step: Int
    @StateObject private var model = SettingsModel()
    @StateObject private var preferences = Preferences.shared

    private static let stepCount = 5

    /// `startStep` exists so `--demo-onboarding=N` can open any step directly. Clicking through
    /// with synthesised events fights whatever the user is actually doing, and steps 3 and 4 went
    /// unlooked-at for several rounds because reaching them meant three real clicks.
    init(startStep: Int = 0, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: min(max(startStep, 0), OnboardingView.stepCount - 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Each step arrives the way a pane switch does — cross-fade and rise. §8.
                .transition(.opacity.combined(with: .offset(y: 8)))
                .id(step)

            footer
        }
        .padding(Theme.Space.panelPadding)
        // The window frosts as one surface with a transparent titlebar, so the traffic lights
        // float over this content and it pads down to clear them. §3.
        .padding(.top, Theme.Space.s20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Palette.NS.bg).opacity(0.6))
        .animation(.easeOut(duration: Theme.Motion.standard), value: step)
        .onAppear { model.refresh() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: switcherStep
        case 1: accessibilityStep
        case 2: modeStep
        case 3: previewsStep
        default: readyStep
        }
    }

    // MARK: - Steps

    private var switcherStep: some View {
        StepScaffold(title: "hexad replaces ⌘Tab",
                     message: "macOS owns ⌘Tab until you turn its switcher off. You can put it "
                            + "back at any time, and hexad restores it automatically when it "
                            + "quits.") {
            OnboardingNote(systemImage: "arrow.uturn.backward",
                           text: "Reversible from Settings, in one click.")
            OnboardingNote(systemImage: "keyboard",
                           text: "Decline and hexad uses ⌥Tab instead.")
        } actions: {
            if SystemSwitcher.state == .hexadOwnsCommandTab {
                StatusPill(text: "hexad now uses ⌘Tab")
                Button("Continue") { step = 1 }
                    .buttonStyle(.hexadPrimary)
            } else {
                Button("Turn it off") {
                    model.disableSystemSwitcher()
                    model.refresh()
                }
                .buttonStyle(.hexadPrimary)

                Button("Not now") { step = 1 }
                    .buttonStyle(.hexadSecondary)
            }
        }
    }

    private var accessibilityStep: some View {
        StepScaffold(glyph: "accessibility",
                     title: "hexad needs Accessibility",
                     message: "This is how hexad reads the list of open windows and raises the "
                            + "one you pick. It is the one permission hexad cannot work without.") {
            OnboardingNote(systemImage: "eye.slash",
                           text: "hexad reads window titles through this, not through Screen "
                               + "Recording — so the whole switcher works on this permission "
                               + "alone. The next step offers a second one, for pictures.")
            OnboardingNote(systemImage: "arrow.clockwise",
                           text: "If the list stays empty after granting, quit and reopen hexad.")
        } actions: {
            if model.isAccessibilityGranted {
                StatusPill(text: "Granted")
                Button("Continue") { step = 2 }
                    .buttonStyle(.hexadPrimary)
            } else {
                Button("Grant…") { model.requestAccessibility() }
                    .buttonStyle(.hexadPrimary)
                Button("Open System Settings") { Permissions.openAccessibilitySettings() }
                    .buttonStyle(.hexadSecondary)
                Button("Skip") { step = 2 }
                    .buttonStyle(.hexadGhost)
            }
        }
    }

    private var modeStep: some View {
        StepScaffold(glyph: "square.on.square",
                     title: "Pick your switcher",
                     message: "hexad is one of these at a time, not all three. Change it whenever "
                            + "you like in Settings.") {
            ForEach(SwitcherMode.allCases) { mode in
                OnboardingChoice(mode: mode,
                                 isSelected: preferences.mode == mode) {
                    preferences.mode = mode
                }
            }
        } actions: {
            Button("Continue") { step = 3 }
                .buttonStyle(.hexadPrimary)
        }
    }

    /// Previews, and the second permission — asked once, here, with the switch showing the
    /// shipped default (on) so the answer is visible rather than assumed.
    private var previewsStep: some View {
        StepScaffold(glyph: "photo",
                     title: "Show the windows themselves?",
                     message: "Each tile can show a live picture of the window instead of its app "
                            + "icon. This is the only part of hexad that needs Screen Recording, "
                            + "and it is the only reason hexad will ever ask for it.") {
            OnboardingNote(systemImage: "hand.raised",
                           text: "Turn it off and hexad never asks for Screen Recording again — "
                               + "everything else works exactly the same.")
            OnboardingNote(systemImage: "bolt",
                           text: "Captures never delay the switcher. It opens with icons and the "
                               + "pictures drop in as they arrive.")
            OnboardingNote(systemImage: "gearshape",
                           text: "Changeable at any time in Settings ▸ Appearance.")

            previewToggleRow
        } actions: {
            if preferences.showsThumbnails && !model.isScreenRecordingGranted {
                Button("Grant Screen Recording") {
                    Permissions.requestScreenRecording()
                    Permissions.openScreenRecordingSettings()
                }
                .buttonStyle(.hexadPrimary)
                Button("Do it later") { step = 4 }
                    .buttonStyle(.hexadSecondary)
            } else {
                if preferences.showsThumbnails {
                    StatusPill(text: "Previews are on")
                }
                Button("Continue") { step = 4 }
                    .buttonStyle(.hexadPrimary)
            }
        }
    }

    /// A real switch inside the step, not a "you can turn this on later" sentence. The decision
    /// is the point of the screen, so the control for it belongs on the screen.
    private var previewToggleRow: some View {
        HStack(spacing: Theme.Space.s12) {
            Image(systemName: "rectangle.inset.filled.badge.record")
                .font(.system(size: 15))
                .foregroundStyle(Color(nsColor: preferences.showsThumbnails
                                       ? Palette.NS.accent
                                       : Palette.NS.textSecondary))
                .frame(width: Theme.Control.rowIcon)

            VStack(alignment: .leading, spacing: 2) {
                Text("Window previews")
                    .font(Font(Theme.Font.bodyEmph))
                    .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))
                Text(previewStatus)
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Space.s12)

            Toggle("", isOn: $preferences.showsThumbnails)
                .labelsHidden()
                .toggleStyle(.hexad)
                .accessibilityLabel("Window previews")
        }
        .padding(.vertical, Theme.Space.s12)
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color(nsColor: preferences.showsThumbnails
                            ? Palette.NS.accentSoft
                            : Palette.NS.surfaceSecondary))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color(nsColor: preferences.showsThumbnails
                                    ? Palette.NS.accent
                                    : Palette.NS.border))
        )
    }

    private var previewStatus: String {
        guard preferences.showsThumbnails else { return "Off — tiles show app icons." }
        return model.isScreenRecordingGranted
            ? "On, and Screen Recording is granted."
            : "On, but Screen Recording is still needed."
    }

    /// The last screen says what hexad actually ended up with.
    ///
    /// Every step above can be declined, and declining is meant to be a real answer — which makes
    /// it entirely possible to finish setup with no permission, no ⌘Tab and no idea. A summary
    /// costs one screen and removes the whole class of "I set it up and nothing happens".
    private var readyStep: some View {
        StepScaffold(glyph: "checkmark.seal",
                     title: "hexad is ready",
                     message: "Here is what it is set up to do. Anything here can be changed in "
                            + "Settings, from the menu bar icon.") {
            OnboardingSummaryRow(systemImage: "keyboard",
                                 label: "Opens with",
                                 value: preferences.primaryBinding.label,
                                 isGood: model.isAccessibilityGranted)
            OnboardingSummaryRow(systemImage: preferences.mode.systemImage,
                                 label: "Switcher",
                                 value: preferences.mode.label,
                                 isGood: true)
            OnboardingSummaryRow(systemImage: "accessibility",
                                 label: "Accessibility",
                                 value: model.isAccessibilityGranted ? "Granted" : "Missing",
                                 isGood: model.isAccessibilityGranted)
            OnboardingSummaryRow(systemImage: "photo",
                                 label: "Previews",
                                 value: previewSummary,
                                 isGood: !preferences.showsThumbnails
                                     || model.isScreenRecordingGranted)

            if !model.isAccessibilityGranted {
                OnboardingNote(systemImage: "exclamationmark.triangle",
                               text: "Without Accessibility hexad cannot list a single window. "
                                   + "Go back a step, or grant it later in Settings ▸ Setup.")
            }
        } actions: {
            Button("Start using hexad") { onFinish() }
                .buttonStyle(.hexadPrimary)
        }
    }

    private var previewSummary: String {
        guard preferences.showsThumbnails else { return "Off" }
        return model.isScreenRecordingGranted ? "On" : "On — permission pending"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.s8) {
            ForEach(0..<Self.stepCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color(nsColor: index == step
                                ? Palette.NS.accent
                                : Palette.NS.border))
                    // The current step is a longer bar, not just a tinted dot — colour alone
                    // never carries meaning. §12.
                    .frame(width: index == step ? 18 : 6, height: 6)
            }

            Spacer()

            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.hexadGhost)
            }
        }
        .animation(.easeOut(duration: Theme.Motion.swap), value: step)
        .padding(.top, Theme.Space.s20)
    }
}

/// The shape every step takes. One scaffold rather than three hand-built layouts, so the glyph,
/// the title and the buttons cannot drift apart between screens.
private struct StepScaffold<Notes: View, Actions: View>: View {

    /// An SF Symbol name, or `nil` to use hexad's own mark — which is what the first step shows,
    /// since a welcome screen is the one place the app should introduce itself by its logo.
    var glyph: String? = nil
    let title: String
    let message: String
    @ViewBuilder let notes: Notes
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s20) {
            Group {
                if let glyph {
                    Image(systemName: glyph)
                        .font(.system(size: 28, weight: .regular))
                } else if let mark = Brand.mark(height: 30) {
                    // A template image, so `.foregroundStyle` below tints it to the accent exactly
                    // as it tints a symbol.
                    Image(nsImage: mark)
                        .renderingMode(.template)
                }
            }
            .foregroundStyle(Color(nsColor: Palette.NS.accent))
            .frame(width: 56, height: 56)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color(nsColor: Palette.NS.accentSoft))
            )

            VStack(alignment: .leading, spacing: Theme.Space.s8) {
                Text(title)
                    .font(Font(Theme.Font.display))
                    .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))

                Text(message)
                    .font(Font(Theme.Font.body))
                    .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Theme.Space.s12) {
                notes
            }

            Spacer(minLength: Theme.Space.s12)

            HStack(spacing: Theme.Space.s12) {
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A contextual icon row — §11's "contextual icons", which is what stops a permission screen
/// reading as a paragraph nobody finishes.
private struct OnboardingNote: View {

    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s12) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: Palette.NS.textTertiary))
                .frame(width: Theme.Control.rowIcon)
            Text(text)
                .font(Font(Theme.Font.caption))
                .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One line of the closing summary: what a thing is set to, and whether that is a working answer.
///
/// The tick is what carries the meaning, not the colour — §12. A row that said "Missing" in red
/// and nothing else would be invisible to anyone who cannot see the red.
private struct OnboardingSummaryRow: View {

    let systemImage: String
    let label: String
    let value: String
    let isGood: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s12) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
                .frame(width: Theme.Control.rowIcon)

            Text(label)
                .font(Font(Theme.Font.body))
                .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))

            Spacer(minLength: Theme.Space.s12)

            Text(value)
                .font(Font(Theme.Font.bodyEmph))
                .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))

            Image(systemName: isGood ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: isGood
                                       ? Palette.NS.accent
                                       : Palette.NS.textTertiary))
        }
        .accessibilityElement(children: .combine)
    }
}

/// The mode choice, as a card rather than a settings row — this is the one decision on the
/// screen, so it gets the weight.
private struct OnboardingChoice: View {

    let mode: SwitcherMode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s12) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 15, weight: isSelected ? .medium : .regular))
                .foregroundStyle(Color(nsColor: isSelected
                                       ? Palette.NS.accent
                                       : Palette.NS.textSecondary))
                .frame(width: Theme.Control.rowIcon)

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.label)
                    .font(Font(isSelected ? Theme.Font.bodyEmph : Theme.Font.body))
                    .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))
                Text(mode.summary)
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Space.s12)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(Color(nsColor: isSelected
                                       ? Palette.NS.accent
                                       : Palette.NS.border))
        }
        .padding(.vertical, Theme.Space.s12)
        .padding(.horizontal, Theme.Space.rowHorizontal)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color(nsColor: isSelected
                            ? Palette.NS.accentSoft
                            : Palette.NS.surfaceSecondary))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color(nsColor: isSelected
                                    ? Palette.NS.accent
                                    : Palette.NS.border))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .animation(.easeOut(duration: Theme.Motion.fast), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}
