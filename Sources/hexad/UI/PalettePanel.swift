import AppKit
import SwiftUI

/// A panel that can take keyboard focus.
///
/// The strip is deliberately non-activating — it appears while a modifier is held and must not
/// make the app it is switching away from resign first. The palette is the opposite: it has a
/// text field, so it *must* become key, and hexad activates for as long as it is open.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The search palette — ⌥Space, type, enter.
///
/// `design-language.md` §10 calls this a typeahead popover and says it is one shared component
/// across every search: a floating `surface` panel with the panel shadow, rows of leading icon +
/// name + secondary hint, and the selected row in `accentSoft`.
final class PaletteController {

    private enum Layout {
        static let width: CGFloat = 480
        /// With a preview beside the list the panel needs room for both, so the width is chosen
        /// at open time rather than fixed.
        static let widthWithPreview: CGFloat = 720
        static let height: CGFloat = 420
        /// Sits above centre. A panel centred vertically covers the thing being searched for.
        static let verticalBias: CGFloat = 0.62
    }

    private let model = PaletteModel()
    private let store: WindowStore
    private var panel: KeyablePanel?
    private var frost: NSVisualEffectView?
    private var keyMonitor: Any?
    /// Whoever was frontmost when the palette opened, so cancelling puts focus back rather than
    /// leaving the user in hexad — an app with no windows and nothing to do.
    private var previousApp: NSRunningApplication?

    /// Called whenever this closes, by any route. The event tap uses it to disarm
    /// release-to-commit.
    var onClose: () -> Void = {}

    private(set) var isOpen = false

    init(store: WindowStore) {
        self.store = store
    }

    // MARK: - Lifecycle

    func prepare() {
        guard panel == nil else { return }

        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0,
                                                     width: Layout.width, height: Layout.height),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let frost = OverlayChrome.makeFrost(cornerRadius: Theme.Radius.overlay)

        let hosting = NSHostingView(rootView: PaletteView(model: model,
                                                          onChoose: { [weak self] index in
            self?.model.selected = index
            self?.close(commit: true)
        }, onClose: { [weak self] index in
            guard let self else { return }
            self.model.selected = index
            self.actOnSelection(self.store.close)
        }))
        hosting.sizingOptions = []
        hosting.frame = frost.bounds
        hosting.autoresizingMask = [.width, .height]
        frost.addSubview(hosting)

        // A container the frost sits inside, so the pop has something to scale. See StripOverlay.
        let container = NSView(frame: panel.contentLayoutRect)
        frost.frame = container.bounds
        frost.autoresizingMask = [.width, .height]
        container.addSubview(frost)

        panel.contentView = container
        self.panel = panel
        self.frost = frost
    }

    func toggle() {
        isOpen ? close(commit: false) : open()
    }

    /// Move the selection from outside — the event tap, when the binding is pressed again while
    /// the palette is already up. The panel's own key monitor never sees that chord, because the
    /// tap swallows it before it reaches any window.
    func move(_ delta: Int) {
        guard isOpen else { return }
        model.move(delta)
    }

    func open() {
        prepare()
        guard let panel, !isOpen else { return }

        previousApp = NSWorkspace.shared.frontmostApplication
        let items = store.snapshot()
        model.reset(with: items)

        // Previews are captured for the whole list, because the pane follows the selection and a
        // capture started on each arrow keypress would always be one keystroke behind.
        if Preferences.shared.showsThumbnails {
            Task { @MainActor in
                ThumbnailProvider.shared.refresh(
                    for: items, targetSize: CGSize(width: 480, height: 300))
            }
        }

        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = Preferences.shared.showsThumbnails
            ? Layout.widthWithPreview
            : Layout.width
        let origin = NSPoint(x: visible.midX - width / 2,
                             y: visible.minY + visible.height * Layout.verticalBias
                                - Layout.height / 2)
        panel.setFrame(NSRect(origin: origin,
                              size: NSSize(width: width, height: Layout.height)),
                       display: true)

        isOpen = true
        BackdropPanel.shared.show()
        NSApp.activate()
        if let frost {
            OverlayChrome.applySurface(frost, isFrosted: Preferences.shared.isFrosted)
            OverlayChrome.present(panel: panel, scaling: frost, makeKey: true)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        installKeyMonitor()
    }

    func close(commit: Bool) {
        guard isOpen else { return }
        isOpen = false
        onClose()
        BackdropPanel.shared.hide()
        removeKeyMonitor()
        if let panel, let frost {
            OverlayChrome.dismiss(panel: panel, scaling: frost)
        } else {
            panel?.orderOut(nil)
        }

        let target = commit ? model.selectedItem : nil
        if let target {
            store.raise(target)
        } else {
            // Nothing chosen: give the keyboard back to whoever had it.
            previousApp?.activate()
        }
        previousApp = nil
    }

    // MARK: - Keys

    /// A local monitor rather than SwiftUI key handling, because the palette needs keys that
    /// belong to the *list* while focus is in the *text field* — arrows, return, ⌘W — and
    /// fighting the responder chain for those is more code than reading them here.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let hasCommand = event.modifierFlags.contains(.command)

        switch Int64(event.keyCode) {
        case Shortcut.Key.escape:
            close(commit: false)
            return true
        case Shortcut.Key.returnKey:
            close(commit: true)
            return true
        case Shortcut.Key.downArrow:
            model.move(1)
            return true
        case Shortcut.Key.upArrow:
            model.move(-1)
            return true
        case Shortcut.Key.w where hasCommand:
            actOnSelection(store.close)
            return true
        case Shortcut.Key.m where hasCommand:
            actOnSelection(store.minimize)
            return true
        case Shortcut.Key.h where hasCommand:
            actOnSelection(store.toggleHidden)
            return true
        case Shortcut.Key.q where hasCommand:
            actOnSelection(store.quit)
            return true
        default:
            return false
        }
    }

    /// Row actions leave the palette open — closing four windows should not mean opening the
    /// palette four times.
    ///
    /// The rebuild waits a beat because AX acts asynchronously: a window asked to close is still
    /// there the instant the call returns, so re-reading immediately shows the list unchanged and
    /// the action looks like it did nothing.
    private func actOnSelection(_ action: @escaping (WindowItem) -> Void) {
        guard let item = model.selectedItem else { return }
        action(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isOpen else { return }
            self.store.rebuild()
            self.model.replaceSource(self.store.snapshot())
        }
    }
}
