import SwiftUI

/// Which switcher hexad is. One of three, never all three at once — see `SwitcherMode`.
///
/// Built as selectable rows rather than a segmented control because each one needs its sentence:
/// "Square" and "Grid" mean nothing to someone who has not seen them yet, and a picker with three
/// opaque words is a setting people change once by accident and never touch again.
struct SwitcherStyleSection: View {

    @ObservedObject var preferences: Preferences

    var body: some View {
        SettingsSection(title: "Switcher style", systemImage: "square.on.square") {
            ForEach(Array(SwitcherMode.allCases.enumerated()), id: \.element) { offset, mode in
                ModeRow(mode: mode,
                        isSelected: preferences.mode == mode,
                        showsDivider: offset < SwitcherMode.allCases.count - 1) {
                    preferences.mode = mode
                }
            }
        }
    }
}

private struct ModeRow: View {

    let mode: SwitcherMode
    let isSelected: Bool
    let showsDivider: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Space.s12) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
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

                Spacer(minLength: Theme.Space.s16)

                // The accent never travels alone — §12. The checkmark is what carries the
                // meaning; the tint is only reinforcement.
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(nsColor: isSelected
                                           ? Palette.NS.accent
                                           : Palette.NS.border))
            }
            .padding(.vertical, Theme.Space.rowVertical)
            .padding(.horizontal, Theme.Space.rowHorizontal)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .onHover { isHovering = $0 }

            if showsDivider {
                Rectangle()
                    .fill(Color(nsColor: Palette.NS.border))
                    .frame(height: 1)
                    .padding(.leading, Theme.Space.rowHorizontal)
            }
        }
        .animation(.easeOut(duration: Theme.Motion.fast), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    /// Selected is a wash, hover is the grey hover fill — never a full accent fill. §10.
    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Color(nsColor: Palette.NS.accentSoft)
        } else if isHovering {
            Color(nsColor: Palette.NS.surfaceHover)
        } else {
            Color.clear
        }
    }
}

/// Switcher — what hexad is, how it behaves while it is open, and what it lists.
///
/// One subject, one pane. These controls used to be spread over three: the style and behaviour
/// switches in General, the preview controls beside the frost switch in Appearance, and nothing
/// at all for the list itself. Changing how the switcher works meant two or three stops, and
/// every stop is a chance to lose the thing you came to change.
struct SwitcherPane: View {

    @ObservedObject var model: SettingsModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        SwitcherStyleSection(preferences: preferences)

        SettingsSection(title: "Behaviour", systemImage: "slider.horizontal.3") {
            SettingsRow(title: "Opens on",
                        description: preferences.opensOnActiveApp
                            ? "Starts on the window you are already in — for looking before you leap."
                            : "Starts on the previous window, so one tap goes back. The macOS habit.",
                        systemImage: "arrow.uturn.backward") {
                HexSegmented(options: [
                    SegmentedOption(value: false, label: "Previous"),
                    SegmentedOption(value: true, label: "Current"),
                ], selection: $preferences.opensOnActiveApp, segmentWidth: 78)
                .accessibilityLabel("Opens on")
            }

            SettingsRow(title: "Search while switching",
                        description: preferences.isSearchEnabled
                            ? "Type any letters to filter the list down."
                            : "Off, so a bare letter jumps to the next app starting with it.",
                        systemImage: "magnifyingglass") {
                Toggle("", isOn: $preferences.isSearchEnabled)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Search while switching")
            }

            if preferences.isSearchEnabled {
                SettingsRow(title: "Remember what I typed",
                            description: "Reopening within a few seconds keeps the last query.",
                            systemImage: "clock.arrow.circlepath") {
                    Toggle("", isOn: $preferences.remembersQuery)
                        .labelsHidden()
                        .toggleStyle(.hexad)
                        .accessibilityLabel("Remember what I typed")
                }
            }

            SettingsRow(title: "Stay open",
                        description: "Keep the switcher up after the keys are released, "
                                   + "instead of switching on release.",
                        systemImage: "pin") {
                Toggle("", isOn: $preferences.staysOpen)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Stay open")
            }

            SettingsRow(title: "Peek while choosing",
                        description: "Pause on a window and it comes forward. Cancel and the "
                                   + "one you were in comes back.",
                        systemImage: "eye") {
                Toggle("", isOn: $preferences.holdToPreview)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Peek while choosing")
            }

            SettingsRow(title: "Come back where I was",
                        description: "Reopening within a few seconds returns to the window you "
                                   + "were looking at, not the top of the list.",
                        systemImage: "arrow.counterclockwise") {
                Toggle("", isOn: $preferences.remembersSelection)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Come back where I was")
            }

            SettingsRow(title: "Full-size preview on space",
                        description: "Press space to see the selected window large enough to "
                                   + "recognise. Needs window previews to show the window itself.",
                        systemImage: "rectangle.expand.vertical") {
                Toggle("", isOn: $preferences.quickLookEnabled)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Full-size preview on space")
            }

            SettingsRow(title: "Mark the wrap",
                        description: "Flash the panel when the cycle goes past the end and starts "
                                   + "again — otherwise a long hold looks like it has stuck.",
                        systemImage: "arrow.triangle.capsulepath",
                        showsDivider: false) {
                Toggle("", isOn: $preferences.showsWrapIndicator)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Mark the wrap")
            }
        }

        WindowListSection(preferences: preferences)
        PerAppModeSection(preferences: preferences)
    }
}

/// A different switcher inside particular apps. **N7.**
///
/// One switcher is the design — see `SwitcherMode` — and this is the exception someone opts into
/// rather than a second way to configure the same thing. Grid on the desktop and Square inside a
/// full-screen editor is a real preference: the mode that suits "show me everything" is not the
/// one that suits "flick back to the last thing".
struct PerAppModeSection: View {

    @ObservedObject var preferences: Preferences

    @State private var isAdding = false
    @State private var candidates: [WindowListSection.AppChoice] = []

    var body: some View {
        SettingsSection(title: "Per-app switcher", systemImage: "app.badge.checkmark") {
            SettingsRow(title: "Use a different switcher in some apps",
                        description: preferences.perAppModes.isEmpty
                            ? "Off. The switcher is \(preferences.mode.label) everywhere."
                            : summary,
                        systemImage: "arrow.triangle.branch",
                        showsDivider: !preferences.perAppModes.isEmpty || isAdding) {
                Button(isAdding ? "Done" : "Add…") {
                    if !isAdding { refreshCandidates() }
                    isAdding.toggle()
                }
                .buttonStyle(.hexadSecondary)
            }

            ForEach(Array(preferences.perAppModes.keys.sorted()), id: \.self) { bundleID in
                SettingsRow(title: name(for: bundleID),
                            description: bundleID,
                            systemImage: preferences.perAppModes[bundleID]?.systemImage
                                ?? "app",
                            showsDivider: isAdding
                                || bundleID != preferences.perAppModes.keys.sorted().last) {
                    HStack(spacing: Theme.Space.s8) {
                        HexSegmented(options: SwitcherMode.allCases.map {
                            SegmentedOption(value: $0, label: $0.label)
                        }, selection: Binding(
                            get: { preferences.perAppModes[bundleID] ?? preferences.mode },
                            set: { preferences.perAppModes[bundleID] = $0 }
                        ), segmentWidth: 62)

                        Button("Remove") {
                            preferences.perAppModes.removeValue(forKey: bundleID)
                        }
                        .buttonStyle(.hexadGhost)
                    }
                }
            }

            if isAdding {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(candidates.filter {
                            preferences.perAppModes[$0.id] == nil
                        }) { choice in
                            SettingsRow(title: choice.name,
                                        description: choice.id,
                                        systemImage: "plus.circle",
                                        showsDivider: choice.id != candidates.last?.id) {
                                Button("Add") {
                                    preferences.perAppModes[choice.id] = preferences.mode
                                }
                                .buttonStyle(.hexadSecondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .onAppear(perform: refreshCandidates)
    }

    private var summary: String {
        let count = preferences.perAppModes.count
        return count == 1
            ? "1 app uses a different switcher."
            : "\(count) apps use a different switcher."
    }

    /// A configured app may not be running, and its bundle id is not a name anyone recognises.
    private func name(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }),
           let name = running.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    private func refreshCandidates() {
        var seen: Set<String> = []
        var list: [WindowListSection.AppChoice] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  seen.insert(id).inserted else { continue }
            list.append(WindowListSection.AppChoice(id: id,
                                                    name: app.localizedName ?? id,
                                                    isRunning: true))
        }
        candidates = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name)
            == .orderedAscending }
    }
}

/// Appearance — everything about how hexad looks, and nothing about what it does.
///
/// Window previews live here now rather than under Switcher. They change what a tile *shows*,
/// which is the same question the frost switch answers, and splitting the tile's appearance
/// across two panes is exactly the jumping this pass is meant to end. The Screen Recording grant
/// is inline for the same reason: the row that needs the permission is the row that asks for it.
struct AppearancePane: View {

    @ObservedObject var preferences: Preferences
    @ObservedObject var model: SettingsModel

    var body: some View {
        SettingsSection(title: "Surface", systemImage: "square.on.square.dashed") {
            SettingsRow(title: "Frosted overlay",
                        description: "Let the desktop show through the switcher.",
                        systemImage: "drop") {
                Toggle("", isOn: $preferences.isFrosted)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Frosted overlay")
            }

            SettingsRow(title: "Appearance",
                        description: "Follow the system, or pin light or dark.",
                        systemImage: "circle.lefthalf.filled",
                        showsDivider: false) {
                HexSegmented(options: Preferences.AppearancePin.allCases.map {
                    SegmentedOption(value: $0, label: $0.label)
                }, selection: $preferences.appearance)
                .accessibilityLabel("Appearance")
            }
        }

        SettingsSection(title: "What a tile shows", systemImage: "rectangle.grid.2x2") {
            SettingsRow(title: "Window previews",
                        description: thumbnailDescription,
                        systemImage: "photo",
                        showsDivider: true) {
                HStack(spacing: Theme.Space.s8) {
                    // The grant button sits in this row and not in Setup. Needing a permission is
                    // the row's own business, and sending someone to another pane to get it is
                    // the jump this reorganisation removes.
                    if preferences.showsThumbnails && !model.isScreenRecordingGranted {
                        Button("Grant…") {
                            Permissions.openScreenRecordingSettings()
                        }
                        .buttonStyle(.hexadPrimary)
                    }
                    Toggle("", isOn: $preferences.showsThumbnails)
                        .labelsHidden()
                        .toggleStyle(.hexad)
                        .accessibilityLabel("Window previews")
                }
            }

            // Square is the only mode with a square tile, so it is the only one that has to choose
            // between cropping a window and letterboxing it. Shown only where it applies — a
            // control that does nothing in the mode you are in is worse than one that is absent.
            if preferences.showsThumbnails && preferences.mode == .square {
                SettingsRow(title: "Preview shape",
                            description: "Fill crops a window to the square tile. "
                                       + "Fit shows all of it, with bars above and below.",
                            systemImage: "aspectratio") {
                    HexSegmented(options: Preferences.ThumbnailFit.allCases.map {
                        SegmentedOption(value: $0, label: $0.label)
                    }, selection: $preferences.thumbnailFit, segmentWidth: 70)
                    .accessibilityLabel("Preview shape")
                }
            }

            SettingsRow(title: "Window titles",
                        description: "Show each window's name on its tile.",
                        systemImage: "textformat") {
                Toggle("", isOn: $preferences.showsTitles)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Window titles")
            }

            SettingsRow(title: "Show the count",
                        description: "\"12 windows\" above the row, so you can see the list is "
                                   + "complete before you start tabbing.",
                        systemImage: "number") {
                Toggle("", isOn: $preferences.showsCount)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Show the count")
            }

            SettingsRow(title: "Buttons on hover",
                        description: "A close and a minimise button on the tile under the "
                                   + "pointer.",
                        systemImage: "cursorarrow.click") {
                Toggle("", isOn: $preferences.showsHoverActions)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Buttons on hover")
            }

            SettingsRow(title: "Apps on their own row",
                        description: "Running apps with no open window sit below the windows "
                                   + "rather than trailing them.",
                        systemImage: "rectangle.split.1x2") {
                Toggle("", isOn: $preferences.separatesApps)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Apps on their own row")
            }

            SettingsRow(title: "Keep previews current",
                        description: "Re-capture the selected window while you look at it. "
                                   + "Costs a capture per pause; a stale preview lies.",
                        systemImage: "arrow.clockwise",
                        showsDivider: false) {
                Toggle("", isOn: $preferences.refreshesPreview)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .disabled(!preferences.showsThumbnails)
                    .accessibilityLabel("Keep previews current")
            }
        }

        SettingsSection(title: "Backdrop", systemImage: "rectangle.on.rectangle") {
            SettingsRow(title: "Hide open apps and windows while switching",
                        description: "Cover what is behind the switcher while you choose.",
                        systemImage: "eye.slash",
                        showsDivider: preferences.hidesWindowsWhileSwitching) {
                Toggle("", isOn: $preferences.hidesWindowsWhileSwitching)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .accessibilityLabel("Hide open apps and windows while switching")
            }

            // Only shown when it can do something. A style picker above a switch that is off is
            // a control that appears broken.
            if preferences.hidesWindowsWhileSwitching {
                SettingsRow(title: "Cover with",
                            description: "What to show instead of your windows.",
                            systemImage: "paintpalette",
                            showsDivider: false) {
                    HexSegmented(options: Preferences.Backdrop.allCases.map {
                        SegmentedOption(value: $0, label: $0.label)
                    }, selection: $preferences.backdrop, segmentWidth: 70)
                    .accessibilityLabel("Backdrop style")
                }
            }
        }
    }

    /// The description changes with the state because this is the one setting that asks for a
    /// second permission, and a row that says "shows previews" while macOS is refusing to give
    /// them is the row people file bugs about.
    private var thumbnailDescription: String {
        guard preferences.showsThumbnails else {
            return "Show each window itself instead of its app icon. Needs Screen Recording."
        }
        return model.isScreenRecordingGranted
            ? "Showing live window previews."
            : "Waiting for Screen Recording — grant it here, then reopen hexad."
    }
}

/// About — last, and honest about what hexad is built from.
struct AboutPane: View {

    let version: String

    var body: some View {
        // The app's own icon, at the size a person recognises it — the same header every app in
        // the family opens About with.
        HStack(spacing: Theme.Space.s16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("hexad")
                    .font(Font(Theme.Font.display))
                    .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))
                Text("Version \(version)")
                    .font(Font(Theme.Font.body))
                    .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
                Text("A window switcher for macOS.")
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(Color(nsColor: Palette.NS.textTertiary))
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, Theme.Space.s8)

        SettingsSection(title: "About", systemImage: "info.circle") {
            SettingsRow(title: "Licence",
                        description: "MIT. Written from public API and observed behaviour.",
                        systemImage: "doc.text",
                        showsDivider: false) {
                EmptyView()
            }
        }

        HStack {
            Spacer()
            // A ghost button here read as a line of text with nothing to click. Quit is a real,
            // deliberate action and needs a real, deliberate control — §10's secondary button.
            Button("Quit hexad") { NSApp.terminate(nil) }
                .buttonStyle(.hexadSecondary)
        }
    }
}
