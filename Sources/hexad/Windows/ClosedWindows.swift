import AppKit

/// Windows that were open a moment ago and are not any more.
///
/// **N2.** The store rebuilds constantly, so it already knows what vanished between two passes —
/// that knowledge was being thrown away. ⇧⌘T for windows costs almost nothing on top of it.
///
/// **What "reopen" can and cannot do, stated plainly.** macOS offers no way to resurrect a
/// specific closed window from outside the app that owned it. What this does is send the app the
/// *reopen* event — the same one a Dock icon click sends — whose documented response is to open a
/// new window: Finder gives a browser window, an editor an untitled document, a browser its own
/// new tab or window. For an app that restores its last session (which most browsers do) that is
/// usually the window you wanted. For one that does not, it is a fresh window of the right app,
/// which is still better than hunting for it in the Dock.
///
/// So the UI calls it **Reopen**, never "restore", and the entry says which app it will reach.
/// Promising to bring back the exact window would be a promise the platform cannot keep.
final class ClosedWindows {

    /// How many to remember. Deep enough to undo a mistaken close from several closes ago,
    /// shallow enough that the list stays a list rather than a history.
    static let capacity = 12

    /// How long an entry stays offerable. A window closed an hour ago is not something anyone is
    /// trying to undo, and offering it makes the list look stale.
    static let lifetime: TimeInterval = 30 * 60

    struct Entry: Identifiable, Equatable {
        let id: String
        let title: String
        let appName: String
        let bundleID: String?
        let icon: NSImage?
        let closedAt: Date

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
    }

    private var entries: [Entry] = []
    /// The previous pass's identities, to diff against.
    private var lastSeen: Set<String> = []
    private var lastItems: [String: WindowItem] = [:]

    /// Feed each rebuild in. Anything that was present last time and is absent now was closed.
    ///
    /// Quitting an app closes all its windows at once, which is not something to offer undo for
    /// window by window — so a pass that loses every window of one app records one entry for it,
    /// not eight.
    func observe(_ items: [WindowItem]) {
        let current = Set(items.filter { !$0.isAppOnly }.map(\.identity))
        defer {
            lastSeen = current
            lastItems = Dictionary(items.filter { !$0.isAppOnly }.map { ($0.identity, $0) },
                                   uniquingKeysWith: { first, _ in first })
        }
        // The first pass has nothing to compare against; treating an empty history as "everything
        // just closed" would fill the list on launch.
        guard !lastSeen.isEmpty else { return }

        let gone = lastSeen.subtracting(current).compactMap { lastItems[$0] }
        guard !gone.isEmpty else { return }

        let stillRunning = Set(NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }
            .map(\.processIdentifier))

        var recorded: Set<pid_t> = []
        for item in gone {
            // The app went with it — one entry, not one per window.
            let appQuit = !stillRunning.contains(item.pid)
            if appQuit {
                guard recorded.insert(item.pid).inserted else { continue }
            }
            record(item, appQuit: appQuit)
        }
    }

    private func record(_ item: WindowItem, appQuit: Bool) {
        let app = NSRunningApplication(processIdentifier: item.pid)
        let entry = Entry(id: item.identity,
                          title: appQuit ? "\(item.appName) — all windows" : item.displayTitle,
                          appName: item.appName,
                          bundleID: app?.bundleIdentifier ?? bundleID(named: item.appName),
                          icon: item.appIcon,
                          closedAt: Date())
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        RuntimeStatus.shared.trace("closed: \(entry.title)")
    }

    /// A terminated process cannot be asked for its bundle id, so fall back to matching the name
    /// against what is installed. Best effort — a nil bundle id only means the entry cannot be
    /// reopened, and it says so rather than offering a button that does nothing.
    private func bundleID(named name: String) -> String? {
        NSWorkspace.shared.runningApplications
            .first { $0.localizedName == name }?
            .bundleIdentifier
    }

    var recent: [Entry] {
        let cutoff = Date().addingTimeInterval(-Self.lifetime)
        return entries.filter { $0.closedAt > cutoff }
    }

    /// Ask the app to open a window. See the note on this type for what that does and does not do.
    @discardableResult
    func reopen(_ entry: Entry) -> Bool {
        guard let bundleID = entry.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Must reach the running process rather than launching a second copy.
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        entries.removeAll { $0.id == entry.id }
        RuntimeStatus.shared.trace("reopen \(entry.appName)")
        return true
    }

    func forget() {
        entries.removeAll()
    }
}
