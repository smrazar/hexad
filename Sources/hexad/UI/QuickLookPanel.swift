import AppKit
import SwiftUI

/// A full-size preview of the selected window, on the space bar.
///
/// **N10.** A switcher tile is small by construction — that is what lets a row of them fit — and
/// there is a class of decision it cannot support: which of these four documents is the one I
/// meant. Space is the gesture the platform already uses for "show me this properly", and Finder
/// has trained everyone on it.
///
/// It is **not** QuickLook the framework. `QLPreviewPanel` previews *files*, and a window is not a
/// file; borrowing the name for the gesture is the point, not the implementation. This shows the
/// capture hexad already has, large, over the switcher.
///
/// Needs Screen Recording, because without it there is no capture to enlarge. With previews off
/// this shows the app icon and the window's own title, which is still more than the tile had —
/// but the setting that offers it says what it depends on rather than silently doing less.
@MainActor
final class QuickLookPanel {

    static let shared = QuickLookPanel()

    /// A fraction of the screen: large enough that the whole point is served, small enough that
    /// the switcher underneath stays visible and the panel reads as *over* it rather than as a
    /// new mode you have to escape.
    private static let screenFraction: CGFloat = 0.62

    private var panel: NSPanel?
    private let model = QuickLookModel()
    private(set) var isOpen = false

    private init() {}

    private func prepare() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 520),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the switcher, which is already at `.popUpMenu`. A preview that appeared behind the
        // thing it is previewing would be invisible, which is a funny way to fail.
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let frost = OverlayChrome.makeFrost(cornerRadius: Theme.Radius.overlay)
        let hosting = NSHostingView(rootView: QuickLookView(model: model))
        hosting.sizingOptions = []
        hosting.frame = frost.bounds
        hosting.autoresizingMask = [.width, .height]
        frost.addSubview(hosting)

        let container = NSView(frame: panel.contentLayoutRect)
        frost.frame = container.bounds
        frost.autoresizingMask = [.width, .height]
        container.addSubview(frost)
        panel.contentView = container
        self.panel = panel
    }

    /// Space again on the same window closes it — the gesture is its own toggle, as it is in
    /// Finder. Space on a *different* window swaps the contents rather than closing.
    func toggle(for item: WindowItem) {
        if isOpen, model.identity == item.identity {
            hide()
            return
        }
        show(item)
    }

    func show(_ item: WindowItem) {
        prepare()
        guard let panel else { return }

        model.identity = item.identity
        model.item = item
        model.title = item.displayTitle
        model.subtitle = item.subtitle
        model.icon = item.appIcon
        model.needsPermission = Preferences.shared.showsThumbnails
            && !Permissions.isScreenRecordingGranted

        // Ask for a fresh capture: a preview opened deliberately is exactly the case where a
        // minutes-old image is worth avoiding, whatever the R5 setting says about the tiles.
        if Preferences.shared.showsThumbnails {
            ThumbnailProvider.shared.refresh(for: [item],
                                             targetSize: CGSize(width: 1400, height: 900),
                                             force: true)
        }

        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = visible.width * Self.screenFraction
        let height = visible.height * Self.screenFraction
        panel.setFrame(NSRect(x: visible.midX - width / 2,
                              y: visible.midY - height / 2,
                              width: width, height: height),
                       display: true)

        isOpen = true
        panel.orderFrontRegardless()
        RuntimeStatus.shared.trace("quick look \(item.displayTitle)")
    }

    func hide() {
        guard isOpen else { return }
        isOpen = false
        panel?.orderOut(nil)
    }
}

final class QuickLookModel: ObservableObject {
    @Published var identity = ""
    /// Kept whole so the view can read through the provider — the cache is keyed on the item, and
    /// holding a copy of the image would freeze whatever had landed at the moment of opening.
    @Published var item: WindowItem?
    @Published var title = ""
    @Published var subtitle = ""
    @Published var icon: NSImage?
    @Published var needsPermission = false
}

private struct QuickLookView: View {

    @ObservedObject var model: QuickLookModel
    @ObservedObject private var thumbnails = ThumbnailProvider.shared

    var body: some View {
        VStack(spacing: Theme.Space.s16) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 2) {
                Text(model.title)
                    .font(Font(Theme.Font.title))
                    .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.subtitle)
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
                    .lineLimit(1)
            }
        }
        .padding(Theme.Space.panelPadding)
        // A capture that lands after the panel opened swaps straight in, which is the usual case:
        // the refresh is asked for at the moment of opening.
        .animation(.easeOut(duration: Theme.Motion.fast), value: thumbnails.generation)
    }

    @ViewBuilder
    private var content: some View {
        if let item = model.item, let image = thumbnails.image(for: item) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Color(nsColor: Palette.NS.border))
                )
        } else {
            // No capture: say why rather than showing an empty rectangle, because "previews are
            // off" and "Screen Recording was refused" are different problems.
            VStack(spacing: Theme.Space.s12) {
                if let icon = model.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 96, height: 96)
                }
                Text(reason)
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var reason: String {
        if model.needsPermission {
            return "Screen Recording is needed to show the window itself."
        }
        return Preferences.shared.showsThumbnails
            ? "Waiting for the capture…"
            : "Turn on window previews to see the window itself."
    }
}
