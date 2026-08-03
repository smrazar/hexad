import AppKit
import SwiftUI

/// What the switcher lists, and in what order.
///
/// These three questions belong together and were previously nowhere at all: the order was
/// hard-coded, every app was always listed, and a second display could not be filtered out. They
/// live beside the switcher style rather than under Appearance, because none of them is about how
/// hexad looks — they are about what it *contains*.
struct WindowListSection: View {

    @ObservedObject var preferences: Preferences

    @State private var isChoosingApps = false
    @State private var candidates: [AppChoice] = []

    /// One app that can be excluded. A value type rather than the `NSRunningApplication`, so the
    /// list does not change shape under the view when something quits mid-scroll.
    struct AppChoice: Identifiable, Hashable {
        let id: String
        let name: String
        let isRunning: Bool
    }

    private var hasSecondDisplay: Bool { NSScreen.screens.count > 1 }

    var body: some View {
        SettingsSection(title: "The list", systemImage: "list.bullet.rectangle") {
            SettingsRow(title: "Order",
                        description: preferences.sortOrder.summary,
                        systemImage: "arrow.up.arrow.down") {
                HexSegmented(options: WindowSort.allCases.map {
                    SegmentedOption(value: $0, label: $0.label)
                }, selection: $preferences.sortOrder, segmentWidth: 62)
                .accessibilityLabel("Window order")
            }

            SettingsRow(title: "Only this display",
                        description: hasSecondDisplay
                            ? "List just the windows on the display the pointer is on."
                            : "Nothing to filter — you have one display.",
                        systemImage: "display.2") {
                Toggle("", isOn: $preferences.limitsToActiveDisplay)
                    .labelsHidden()
                    .toggleStyle(.hexad)
                    .disabled(!hasSecondDisplay)
                    .accessibilityLabel("Only this display")
            }

            SettingsRow(title: "Skip these apps",
                        description: excludedSummary,
                        systemImage: "eye.slash",
                        showsDivider: isChoosingApps) {
                Button(isChoosingApps ? "Done" : "Choose…") {
                    if !isChoosingApps { refreshCandidates() }
                    isChoosingApps.toggle()
                }
                .buttonStyle(.hexadSecondary)
            }

            // Inline rather than a sheet. A sheet is another place to be, and the complaint this
            // whole pass answers is having to go somewhere else to change one thing.
            if isChoosingApps {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(candidates) { choice in
                            appRow(choice)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .onAppear(perform: refreshCandidates)
    }

    private func appRow(_ choice: AppChoice) -> some View {
        let isExcluded = preferences.excludedBundleIDs.contains(choice.id)
        return SettingsRow(title: choice.name,
                           description: choice.isRunning
                               ? choice.id
                               : "\(choice.id) — not running",
                           systemImage: isExcluded ? "eye.slash" : "eye",
                           showsDivider: choice.id != candidates.last?.id) {
            Toggle("", isOn: Binding(
                get: { isExcluded },
                set: { shouldExclude in
                    var updated = preferences.excludedBundleIDs
                    if shouldExclude {
                        updated.insert(choice.id)
                    } else {
                        updated.remove(choice.id)
                    }
                    preferences.excludedBundleIDs = updated
                }))
                .labelsHidden()
                .toggleStyle(.hexad)
                .accessibilityLabel("Skip \(choice.name)")
        }
    }

    private var excludedSummary: String {
        let count = preferences.excludedBundleIDs.count
        guard count > 0 else { return "Every app is listed. Skip the ones you never switch to." }
        return count == 1 ? "1 app is skipped." : "\(count) apps are skipped."
    }

    /// Every app in the Dock right now, plus anything already excluded that is not running —
    /// otherwise an exclusion could only be undone while its app happened to be open.
    private func refreshCandidates() {
        var seen: Set<String> = []
        var list: [AppChoice] = []

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  seen.insert(id).inserted else { continue }
            list.append(AppChoice(id: id, name: app.localizedName ?? id, isRunning: true))
        }

        for id in preferences.excludedBundleIDs where seen.insert(id).inserted {
            list.append(AppChoice(id: id, name: id, isRunning: false))
        }

        candidates = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name)
            == .orderedAscending }
    }
}
