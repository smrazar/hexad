import AppKit

/// What sits behind the switcher while it is open.
///
/// The grid had a dimmed desktop and the other two modes had nothing, because the grid painted
/// its own window background. Making it a panel of its own means every mode gets the same choice
/// and the setting is one thing rather than three — "hide open apps and windows while switching".
///
/// It is a separate window rather than a layer inside each overlay because the overlays are
/// different sizes and the backdrop is always the whole screen. Growing an overlay to full screen
/// just to tint it would break every layout inside it.
final class BackdropPanel {

    /// One instance. Three modes share one backdrop; two would fight over the same screen.
    static let shared = BackdropPanel()


    /// Enough to push the desktop back without hiding what is behind the cards.
    private static let dimOpacity: CGFloat = 0.45
    /// The solid fill is the app's own background, not black — it belongs to the same surface
    /// family as everything drawn on top of it.
    private static let solidOpacity: CGFloat = 0.96

    private var panel: NSPanel?
    private var content: NSView?

    private(set) var isVisible = false

    // MARK: - Lifecycle

    func prepare() {
        guard panel == nil else { return }

        let panel = NSPanel(contentRect: NSScreen.main?.frame ?? .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // One step below the switcher, so it can never end up in front of the thing it is
        // supposed to sit behind.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let container = NSView(frame: panel.contentLayoutRect)
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        panel.contentView = container

        self.panel = panel
        self.content = container
    }

    // MARK: - Showing

    func show() {
        guard Preferences.shared.hidesWindowsWhileSwitching else { return }
        prepare()
        guard let panel, !isVisible else { return }

        let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
        panel.setFrame(frame, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        applyStyle(size: frame.size)

        isVisible = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            // Slightly slower than the switcher's own pop: the backdrop is scenery and should
            // not arrive first, or it reads as the main event.
            context.duration = Theme.Motion.Pop.inDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Theme.Motion.Pop.outDuration
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    // MARK: - Style

    private func applyStyle(size: CGSize) {
        guard let content else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        content.layer?.backgroundColor = nil

        switch Preferences.shared.backdrop {
        case .wallpaper:
            // Show the desktop picture itself. Actually hiding every other app's windows is not
            // something an app can do, so the honest version of "just the wallpaper" is to paint
            // the wallpaper over them.
            //
            // **Aspect-fill, centre-cropped — not stretched.** This drew with
            // `scaleAxesIndependently`, which distorts the picture to whatever shape the screen is,
            // so the backdrop never lined up with the real desktop behind it. macOS's own default
            // is Fill Screen: scale until both axes are covered, centre, crop the overflow. That is
            // exactly `resizeAspectFill`, and a layer does it correctly at any backing scale where
            // an NSImageView has no matching mode at all.
            let wallpaper = NSView(frame: NSRect(origin: .zero, size: size))
            wallpaper.wantsLayer = true
            wallpaper.autoresizingMask = [.width, .height]
            wallpaper.layer?.contentsGravity = .resizeAspectFill
            wallpaper.layer?.masksToBounds = true
            if let image = desktopImage() {
                wallpaper.layer?.contents = image
            }
            content.addSubview(wallpaper)

        case .frosted:
            let frost = OverlayChrome.makeFrost(cornerRadius: 0)
            frost.frame = NSRect(origin: .zero, size: size)
            frost.autoresizingMask = [.width, .height]
            content.addSubview(frost)

        case .dim:
            content.layer?.backgroundColor = NSColor.black
                .withAlphaComponent(Self.dimOpacity).cgColor

        case .solid:
            content.layer?.backgroundColor = Palette.NS.bg
                .withAlphaComponent(Self.solidOpacity).cgColor
        }
    }

    /// The current desktop picture for the screen the switcher is on. `nil` if macOS will not
    /// say — a dynamic wallpaper, or one hexad has no permission to read — in which case the
    /// backdrop is simply empty rather than wrong.
    private func desktopImage() -> NSImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: url)
    }
}
