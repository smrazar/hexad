import AppKit

/// Windows grouped by the display they sit on, for the grid.
///
/// AX reports window positions in a top-left origin space; `NSScreen` uses bottom-left. Comparing
/// them directly puts every window on the wrong display the moment a second monitor is not
/// exactly aligned, which is precisely when a grid grouped by display is worth having.
enum DisplayGrouping {

    struct Group: Identifiable {
        let id: Int
        let name: String
        let items: [WindowItem]
    }

    static func group(_ items: [WindowItem]) -> [Group] {
        let screens = NSScreen.screens
        guard screens.count > 1 else {
            // One display: a single unnamed group, so the grid does not add a heading that says
            // nothing. Minimized windows still belong here.
            return items.isEmpty ? [] : [Group(id: 0, name: "", items: items)]
        }

        var buckets: [Int: [WindowItem]] = [:]
        for item in items {
            buckets[screenIndex(for: item, in: screens), default: []].append(item)
        }
        return screens.indices.compactMap { index in
            guard let bucket = buckets[index], !bucket.isEmpty else { return nil }
            return Group(id: index, name: name(of: screens[index], index: index), items: bucket)
        }
    }

    /// Falls back to the main display when a window reports no frame — a minimized window often
    /// does not, and dropping it entirely would be worse than putting it somewhere plausible.
    private static func screenIndex(for item: WindowItem, in screens: [NSScreen]) -> Int {
        guard let frame = item.frame else { return 0 }
        let flipped = flipToScreenSpace(frame, screens: screens)
        let centre = CGPoint(x: flipped.midX, y: flipped.midY)

        if let index = screens.firstIndex(where: { $0.frame.contains(centre) }) { return index }
        // Off every display — dragged half off, or on a display that just went away. Nearest wins.
        return screens.indices.min { lhs, rhs in
            distance(centre, screens[lhs].frame) < distance(centre, screens[rhs].frame)
        } ?? 0
    }

    /// AX y grows downward from the top of the primary display; NSScreen y grows upward from its
    /// bottom. The primary screen's height is the pivot for both.
    private static func flipToScreenSpace(_ rect: CGRect, screens: [NSScreen]) -> CGRect {
        guard let primary = screens.first else { return rect }
        let flippedY = primary.frame.maxY - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private static func name(of screen: NSScreen, index: Int) -> String {
        let label = screen.localizedName
        return label.isEmpty ? "Display \(index + 1)" : label
    }
}
