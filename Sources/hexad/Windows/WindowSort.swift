import AppKit

/// How the window list is ordered.
///
/// MRU is what a switcher is *for* — the whole gesture is "back to the last thing" — so it is the
/// default and the other two are for people who want a list that does not move under them. A
/// stable order is a real preference: someone who has learnt that Mail is the fourth tile does not
/// want it to be the second tomorrow.
enum WindowSort: String, Codable, CaseIterable, Identifiable {
    case recent, alphabetical, byApp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return "Recent"
        case .alphabetical: return "A–Z"
        case .byApp: return "By app"
        }
    }

    var summary: String {
        switch self {
        case .recent: return "Most recently used first."
        case .alphabetical: return "By window title, so the order never moves."
        case .byApp: return "Grouped by app name, windows together."
        }
    }

    /// Applied to the windowed tier only. The app-only rows are appended after it by the store and
    /// keep their own order — a running app with nothing open is a footnote to the list, and
    /// sorting it in among real windows is what the two-tier split exists to prevent.
    func apply(to items: [WindowItem]) -> [WindowItem] {
        switch self {
        case .recent:
            // Already in recency order when it arrives — the store builds it that way.
            return items
        case .alphabetical:
            return items.sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        case .byApp:
            // Stable within an app: `enumerated` breaks ties by arrival, so windows of one app
            // keep the recency order the store gave them.
            return items.enumerated().sorted { lhs, rhs in
                let byName = lhs.element.appName.localizedCaseInsensitiveCompare(
                    rhs.element.appName)
                if byName != .orderedSame { return byName == .orderedAscending }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
    }
}
