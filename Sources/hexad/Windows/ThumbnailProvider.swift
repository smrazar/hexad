import AppKit
import ScreenCaptureKit

/// Window previews, captured on demand.
///
/// This is the only part of hexad that needs Screen Recording, which is why it is opt-in and why
/// nothing here runs unless the preference is on — PLAN.md §2 makes "one permission in v1" a
/// stated promise, and a background capture nobody asked for would quietly break it.
///
/// **Never on the hot path.** A capture costs tens of milliseconds per window and the overlay has
/// a 16ms budget to appear (§11). So the strip opens with app icons and thumbnails arrive after,
/// swapping in as each one lands. A switcher that waited for screenshots would be exactly the
/// "slow" complaint hexad exists to answer.
@MainActor
final class ThumbnailProvider: ObservableObject {

    static let shared = ThumbnailProvider()

    /// Captures are reused for this long. Long enough that cycling through the list does not
    /// re-shoot every window, short enough that a preview is never obviously from another task.
    private static let cacheLifetime: TimeInterval = 20

    private struct Entry {
        let image: NSImage
        let capturedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: Task<Void, Never>?

    /// Bumped whenever a new image lands, so a view can redraw without diffing a dictionary.
    @Published private(set) var generation = 0

    private init() {}

    func image(for item: WindowItem) -> NSImage? {
        guard let entry = cache[item.thumbnailKey] else { return nil }
        guard Date().timeIntervalSince(entry.capturedAt) < Self.cacheLifetime else { return nil }
        return entry.image
    }

    /// Kicks off a capture pass for whatever is on screen right now. Safe to call on every
    /// overlay open: a pass already running is left alone rather than stacked on.
    ///
    /// `force` re-captures even something already cached. Needed by two callers that specifically
    /// want a *current* image rather than any image: the preview-freshness setting (R5), and the
    /// full-size preview, which is opened precisely because the tile was not good enough to
    /// decide by — showing it a minutes-old capture would defeat the gesture.
    func refresh(for items: [WindowItem], targetSize: CGSize, force: Bool = false) {
        guard Preferences.shared.showsThumbnails else { return }
        guard Permissions.isScreenRecordingGranted else { return }
        guard inFlight == nil else { return }

        let wanted = force ? items : items.filter { image(for: $0) == nil }
        guard !wanted.isEmpty else { return }

        inFlight = Task { [weak self] in
            await self?.capture(wanted, targetSize: targetSize)
            self?.inFlight = nil
        }
    }

    func invalidate() {
        cache.removeAll()
    }

    // MARK: - Capture

    private func capture(_ items: [WindowItem], targetSize: CGSize) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false
        ) else { return }

        // hexad's own windows are **not** excluded. They used to be, which is why hexad's Settings
        // window was the one entry in the switcher that never got a preview. There is no risk of
        // capturing the overlay that is asking for the capture: matching is driven by the window
        // list, and `WindowStore` already keeps hexad's borderless panels out of it.
        let candidates = content.windows

        for item in items {
            guard let window = Self.match(item, in: candidates) else { continue }
            guard let image = await Self.shoot(window, targetSize: targetSize) else { continue }
            cache[item.thumbnailKey] = Entry(image: image, capturedAt: Date())
            generation &+= 1
        }
    }

    /// Capture one window, **at the window's own aspect ratio**.
    ///
    /// This is where "fill the tile" was actually broken, and no amount of `.aspectRatio(.fill)` in
    /// the view could have fixed it. The caller passes the tile size, which for Square is a square;
    /// setting `width`/`height` to that with `scalesToFit` makes ScreenCaptureKit render a
    /// landscape window *letterboxed into a square buffer*. The bars are then part of the image, so
    /// a view told to fill a square with it dutifully fills the square — bars and all.
    ///
    /// So the buffer is shaped like the window and only its longest edge is bounded. The image that
    /// comes back is the window and nothing else, and cropping it to any tile shape is then the
    /// view's business, which is where that decision belongs.
    private static func shoot(_ window: SCWindow, targetSize: CGSize) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()

        // Capture at tile scale rather than full resolution: a 6K window scaled down to 260pt costs
        // memory and time for detail nobody sees. `longestEdge` is doubled for Retina.
        let longestEdge = max(targetSize.width, targetSize.height) * 2
        let frame = window.frame
        let aspect = frame.height > 0 ? frame.width / frame.height : 1
        let pixelWidth: CGFloat
        let pixelHeight: CGFloat
        if aspect >= 1 {
            pixelWidth = longestEdge
            pixelHeight = (longestEdge / aspect).rounded()
        } else {
            pixelHeight = longestEdge
            pixelWidth = (longestEdge * aspect).rounded()
        }
        config.width = max(Int(pixelWidth), 1)
        config.height = max(Int(pixelHeight), 1)
        config.showsCursor = false
        config.scalesToFit = true

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        ) else { return nil }
        // Sized from the image itself, not from the tile — handing back a square NSImage wrapping a
        // landscape bitmap would reintroduce the same distortion one layer up.
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2,
                                                      height: cgImage.height / 2))
    }

    /// AX and ScreenCaptureKit describe the same windows through two systems that share no
    /// identifier — `_AXUIElementGetWindow` is private, and hexad is clean-room MIT. So they are
    /// matched on what both can see: the owning process, then the title, then the frame.
    ///
    /// Title first because it survives a window being moved; frame second because two windows of
    /// the same app often share a title ("Untitled") and never share a position.
    private static func match(_ item: WindowItem, in windows: [SCWindow]) -> SCWindow? {
        let sameApp = windows.filter { $0.owningApplication?.processID == item.pid }
        guard !sameApp.isEmpty else { return nil }

        if !item.title.isEmpty {
            let byTitle = sameApp.filter { $0.title == item.title }
            if byTitle.count == 1 { return byTitle[0] }
            if let frame = item.frame,
               let exact = byTitle.first(where: { Self.isSameFrame($0.frame, frame) }) {
                return exact
            }
        }

        if let frame = item.frame,
           let exact = sameApp.first(where: { Self.isSameFrame($0.frame, frame) }) {
            return exact
        }

        // One window, one app, no ambiguity to resolve.
        return sameApp.count == 1 ? sameApp[0] : nil
    }

    /// AX reports in top-left origin coordinates and ScreenCaptureKit in its own, so only the
    /// size is compared — and loosely, because the two disagree by a point on some windows.
    private static func isSameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
    }
}
