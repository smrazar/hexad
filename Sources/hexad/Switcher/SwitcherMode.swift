import Foundation

/// Which switcher hexad *is*.
///
/// The three modes were built as three things that could all be open at once, each on its own
/// shortcut, and that was wrong: they are three answers to the same question, and offering all of
/// them at the same time makes the user decide which switcher they are using every time they
/// switch. One is chosen, the bindings open that one, and the other two are not listening.
enum SwitcherMode: String, Codable, CaseIterable, Identifiable {
    case square, list, grid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .square: return "Square"
        case .list: return "List"
        case .grid: return "Grid"
        }
    }

    var summary: String {
        switch self {
        case .square: return "A row of square tiles, most recently used first. Hold to cycle."
        case .list: return "A vertical list with a preview beside it."
        case .grid: return "Every window at once, grouped by display."
        }
    }

    var systemImage: String {
        switch self {
        case .square: return "square.on.square"
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }

    /// Whether the mode cycles while the binding's modifier is held, or simply opens and waits.
    ///
    /// The strip is a gesture — press, cycle, release, gone. The palette owns the keyboard because
    /// it has a text field, and the grid is somewhere you land and look around. Holding a modifier
    /// down to type a search query would be absurd, so those two toggle instead.
    var isHeldToCycle: Bool { self == .square }
}
