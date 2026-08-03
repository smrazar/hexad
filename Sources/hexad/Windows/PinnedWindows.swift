import Foundation

/// Windows the user has nailed to the front of the list.
///
/// **N1.** ⌘1…⌘9 jump by *position*, and position moves with most-recently-used order — so the
/// muscle memory those keys exist to serve can never actually form: the window that was slot 3 a
/// minute ago is slot 1 now. A pinned window always occupies the same slot, which is what makes
/// "⌘2 is my editor" a thing a hand can learn.
///
/// Pins are stored as `WindowItem.identity` strings, which are a heuristic (pid + title + rounded
/// size) rather than a real window id — AX gives no id without the private call clean-room MIT
/// rules out. The consequence is honest and worth stating: **a pin does not survive quitting the
/// app it points at**, because the pid changes. It survives moving, resizing and reordering, which
/// is what it is actually for.
struct PinnedWindows: Codable, Equatable {

    /// Slot number (1…9) to window identity. Sparse on purpose — pinning slot 5 and nothing else
    /// is a reasonable thing to do, and shuffling the others up to close the gap would defeat the
    /// point of a fixed position.
    private(set) var slots: [Int: String]

    static let maxSlot = 9

    init(slots: [Int: String] = [:]) {
        self.slots = slots
    }

    var isEmpty: Bool { slots.isEmpty }

    func identity(forSlot slot: Int) -> String? { slots[slot] }

    func slot(for identity: String) -> Int? {
        slots.first { $0.value == identity }?.key
    }

    func isPinned(_ identity: String) -> Bool { slot(for: identity) != nil }

    /// Pin to a specific slot, replacing whatever was there.
    func pinning(_ identity: String, to slot: Int) -> PinnedWindows {
        guard (1...Self.maxSlot).contains(slot) else { return self }
        var updated = slots
        // One window cannot hold two slots — pinning it again moves it rather than duplicating it.
        updated = updated.filter { $0.value != identity }
        updated[slot] = identity
        return PinnedWindows(slots: updated)
    }

    /// Pin to the lowest free slot. What the keyboard shortcut uses, because asking "which slot?"
    /// mid-gesture is one question too many.
    func pinningToFirstFree(_ identity: String) -> PinnedWindows? {
        guard !isPinned(identity) else { return nil }
        guard let free = (1...Self.maxSlot).first(where: { slots[$0] == nil }) else { return nil }
        return pinning(identity, to: free)
    }

    func unpinning(_ identity: String) -> PinnedWindows {
        PinnedWindows(slots: slots.filter { $0.value != identity })
    }

    /// Toggle, which is what a single key has to do.
    func toggling(_ identity: String) -> PinnedWindows {
        isPinned(identity) ? unpinning(identity) : (pinningToFirstFree(identity) ?? self)
    }

    /// Reorder a list so pinned windows lead it, in slot order.
    ///
    /// Applied after sorting rather than before: a pin outranks the sort, which is the entire
    /// point of pinning. Windows whose pin no longer matches anything on screen are simply absent,
    /// and their slot stays reserved rather than collapsing — so a pinned window that was closed
    /// and reopened returns to its own slot.
    func apply(to items: [WindowItem]) -> [WindowItem] {
        guard !slots.isEmpty else { return items }
        var pinned: [(slot: Int, item: WindowItem)] = []
        var rest: [WindowItem] = []
        for item in items {
            if let slot = slot(for: item.identity) {
                pinned.append((slot, item))
            } else {
                rest.append(item)
            }
        }
        guard !pinned.isEmpty else { return items }
        return pinned.sorted { $0.slot < $1.slot }.map(\.item) + rest
    }
}
