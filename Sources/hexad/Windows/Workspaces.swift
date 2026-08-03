import AppKit

/// A named set of windows, raised together.
///
/// **N5.** "Get me back to what I was doing" is a different question from "switch to a window",
/// and the switcher already has everything needed to answer it: the window list, and a way to
/// raise one. A workspace is that list, named, replayed in order.
///
/// **What it is not.** It does not launch anything, move anything, or lay anything out. It raises
/// what is already open, in the order it was captured, so the last one ends up in front. Restoring
/// a workspace whose windows are gone raises what remains and says how many were missing — a
/// silent partial restore would be worse than a refusal, because you would not know what you were
/// looking at.
///
/// Identities are the same heuristic used everywhere else (pid + title + rounded size), so a
/// workspace does not survive quitting the apps in it. Stated in the UI rather than hidden: this
/// is for "back to the three windows I had a minute ago", not for session management.
struct Workspace: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// Front-most last, so replaying in order leaves the right window in front.
    var identities: [String]
    /// For the summary line — identities are unreadable and a saved set nobody can identify is a
    /// set nobody restores.
    var appNames: [String]
    var savedAt: Date

    var summary: String {
        let unique = Array(NSOrderedSet(array: appNames)) as? [String] ?? []
        let names = unique.prefix(3).joined(separator: ", ")
        let extra = unique.count > 3 ? " +\(unique.count - 3)" : ""
        return "\(identities.count) window\(identities.count == 1 ? "" : "s") · \(names)\(extra)"
    }
}

/// Saving, restoring and persisting workspaces.
enum WorkspaceStore {

    /// Enough for a handful of real contexts. A list that grows without limit needs management UI
    /// that this does not earn.
    static let maxWorkspaces = 8

    /// Capture the current list as a workspace.
    ///
    /// Reversed on purpose: the store hands back most-recently-used first, and restoring has to
    /// raise them back-to-front so the window that was in front ends up in front again.
    static func capture(_ items: [WindowItem], named name: String) -> Workspace {
        let windows = items.filter { !$0.isAppOnly }
        return Workspace(id: UUID().uuidString,
                         name: name,
                         identities: windows.map(\.identity).reversed(),
                         appNames: windows.map(\.appName),
                         savedAt: Date())
    }

    /// Raise everything in the workspace that still exists.
    ///
    /// Returns how many were found and how many were expected, so the caller can be honest about
    /// a partial restore. The raises are spaced: several `AXRaise` calls in the same run-loop turn
    /// arrive faster than WindowServer reorders, and the result is a stack in the wrong order.
    @discardableResult
    static func restore(_ workspace: Workspace, from items: [WindowItem],
                        using store: WindowStore) -> (found: Int, expected: Int) {
        let byIdentity = Dictionary(items.map { ($0.identity, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let targets = workspace.identities.compactMap { byIdentity[$0] }

        for (offset, item) in targets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(offset) * 0.08) {
                store.raise(item)
            }
        }
        RuntimeStatus.shared.trace(
            "restore workspace '\(workspace.name)' · \(targets.count)/\(workspace.identities.count)")
        return (targets.count, workspace.identities.count)
    }
}
