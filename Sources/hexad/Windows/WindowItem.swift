import AppKit
import ApplicationServices

/// One switchable target: a window, or a running app that has none.
///
/// `thumbnail` is deliberately present and unused in v1 — PLAN.md §1 keeps the slot so v2's
/// ScreenCaptureKit work is an addition rather than a reshape of everything that reads this.
struct WindowItem {
    /// `nil` for a running app with no open window. Every switcher on this platform lists those —
    /// an app in the Dock with no window is still somewhere you switch *to*, and activating it is
    /// how you get its window back. Choosing one activates the app instead of raising a window.
    let element: AXUIElement?
    let pid: pid_t
    let appName: String
    let appIcon: NSImage?
    let title: String
    let isMinimized: Bool
    /// A window occupying a Space of its own.
    ///
    /// From `AXFullScreen`, which is documented — not the private Spaces call hexad stays clear
    /// of. It matters twice: such a window needs a marker, because its preview looks like every
    /// other maximised window, and raising it moves the whole desktop to another Space, which is
    /// startling if nothing warned you.
    let isFullScreen: Bool
    /// The AX subrole, kept because deduplication needs to tell a floating duplicate of a window
    /// apart from a second real window. Empty when the window reports none.
    var subrole: String = ""
    /// In AX screen coordinates, origin top-left. `nil` when the window will not report one,
    /// which minimized windows sometimes do not. The grid groups by display, so it needs this.
    let frame: CGRect?

    /// A running app with nothing open. Listed after every real window, never among them.
    var isAppOnly: Bool { element == nil }

    /// An app with no windows, built from the app alone.
    static func app(_ app: NSRunningApplication) -> WindowItem {
        WindowItem(element: nil,
                   pid: app.processIdentifier,
                   appName: app.localizedName ?? "Unknown",
                   appIcon: app.icon,
                   title: "",
                   isMinimized: false,
                   isFullScreen: false,
                   frame: nil)
    }

    /// What the overlay puts under the icon. An untitled window is common — a Finder desktop
    /// window, a freshly opened panel — and showing an empty label reads as a broken row,
    /// so it falls back to the app name.
    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    /// The second line. An app-only entry says so rather than repeating its own name, which is
    /// what tells the user why it has no window rather than looking like a missing title.
    var subtitle: String {
        if isAppOnly { return "No open windows" }
        // Full screen is worth saying in words as well as in a badge: raising one of these takes
        // the whole desktop to another Space, and being told that after it happens is too late.
        return isFullScreen ? "\(appName) · full screen" : appName
    }

    /// The key a captured preview is cached under.
    ///
    /// Deliberately not the frame: a window that is moved is still the same window, and keying
    /// on position would throw away every preview the moment someone drags something.
    var thumbnailKey: String {
        "\(pid)|\(title)"
    }

    /// A heuristic identity, stable across rebuilds, used for per-window recency.
    ///
    /// AX will not hand out a window identifier without the private call that clean-room MIT
    /// rules out, so identity is inferred: the process, the title, and the window's size rounded
    /// to 20pt. Size is in because two untitled windows of one app are otherwise the same string;
    /// it is *rounded* because a window resized by a few points is still the same window, and an
    /// exact size would make every drag look like a new one.
    ///
    /// ponytail: two same-size untitled windows of one app still collide. The cost of that is
    /// their relative order, not a wrong switch — both entries still raise their own AX element.
    var identity: String {
        let size = frame.map { "\(Int($0.width / 20))×\(Int($0.height / 20))" } ?? "-"
        return "\(pid)|\(title)|\(size)"
    }
}

/// `AXValue` boxes points and sizes, so they cannot come back through the generic above — the
/// cast succeeds and the value is a `CFType` nobody can read. Unbox them here instead.
func axFrame(_ element: AXUIElement) -> CGRect? {
    // Written out per type rather than through a generic: `AXValueGetValue` takes a raw pointer,
    // and forming one to a generic `T` is unsound because `T` may hold an object reference.
    func boxed(_ attribute: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        return (raw as! AXValue)
    }

    guard let positionValue = boxed(kAXPositionAttribute),
          let sizeValue = boxed(kAXSizeAttribute)
    else { return nil }

    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue, .cgPoint, &origin),
          AXValueGetValue(sizeValue, .cgSize, &size)
    else { return nil }

    return CGRect(origin: origin, size: size)
}

/// Reading an AX attribute is four lines of ceremony every time, and the ceremony is where the
/// mistakes live. One generic, used everywhere.
func axCopy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value as? T
}
