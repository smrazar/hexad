import AppKit
import Combine
import SwiftUI

/// A plain titled window hosting a SwiftUI view, built lazily and kept alive between opens.
///
/// `isReleasedWhenClosed` defaults to true on a window created in code, which deallocates it on
/// the first close and crashes on the second open. It is the standard way a menu-bar app's
/// Settings window ships broken, so it is set here once rather than remembered per window.
final class AppWindow {

    private var window: NSWindow?
    private var hasSavedFrame = false
    private var frost: NSVisualEffectView?
    private var frostObserver: AnyCancellable?
    private let title: String
    private let size: NSSize
    private let content: () -> AnyView

    init<Content: View>(title: String, size: NSSize, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.size = size
        self.content = { AnyView(content()) }
    }

    func show() {
        let isFirstShow = window == nil
        if isFirstShow { build() }
        // An .accessory app has no Dock icon to click, so nothing else will bring it forward.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Centre once, and only a window macOS has no remembered frame for. Re-centring on every
        // open throws away wherever the user put it.
        if isFirstShow, !hasSavedFrame { window?.center() }
    }

    func close() {
        window?.close()
    }

    private func build() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = title
        window.isReleasedWhenClosed = false

        // One NSVisualEffectView, as the window's content view — never a second one, and never a
        // blur inside a transparent window. Blurring at the window level is what AppKit expects,
        // so the titlebar, corner rounding and shadow stay correct. design-language.md §3.
        //
        // This frosts the *whole* window, which is only half the rule: "chrome frosts; content
        // does not". The content pane paints an opaque fill over this — see SettingsView — so the
        // sidebar shows the desktop through it and the pane beside it does not. That is done by
        // painting rather than by a second effect view, which §13 forbids outright.
        let frost = NSVisualEffectView()
        frost.material = .sidebar
        frost.blendingMode = .behindWindow
        frost.state = .active

        let hosting = NSHostingView(rootView: content())
        // Without this, the hosting view publishes an intrinsic content size and auto layout
        // sizes the *window* from it. Text that wraps has no natural width, so SwiftUI picks a
        // narrow ideal one and grows downwards — which is how this shipped as a full-height
        // strip about a hundred points wide, with no resize control to escape it.
        hosting.sizingOptions = []
        hosting.frame = frost.bounds
        hosting.autoresizingMask = [.width, .height]
        frost.addSubview(hosting)
        window.contentView = frost

        // The window frosts as one surface, so the titlebar cannot be a separate opaque strip.
        // The traffic lights then float over the content, which is why the sidebar pads down.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        window.setContentSize(size)
        // Remembered across launches. Re-centring every time throws away wherever the user put it,
        // and AppKit will do the remembering if it is given a name to file it under.
        let autosaveName = "hexad.\(title.replacingOccurrences(of: " ", with: "-"))"
        // Asked *before* the window is named, because naming it is what moves it: AppKit shifts a
        // window created at the origin up to clear the Dock, so by the time anyone looks, the
        // frame is (0, 42) rather than zero. Testing the origin therefore reads a brand-new
        // window as one the user had already placed, which is how the welcome window shipped
        // opening in the bottom-left corner on a first run.
        hasSavedFrame = UserDefaults.standard.object(forKey: "NSWindow Frame \(autosaveName)") != nil
        window.setFrameAutosaveName(autosaveName)
        // A floor, and it has to be a *realistic* one. At 420pt the sidebar takes 168 of it and
        // every settings row had to fit a label, a description and a control into what was left —
        // so the description wrapped one word per line and the status pill turned into a vertical
        // column of letters. The floor is now derived from the window's own design size rather
        // than being a number small enough to guarantee the layout breaks.
        window.contentMinSize = NSSize(width: size.width * 0.86, height: size.height * 0.7)
        self.window = window
        self.frost = frost

        // The frost switch has to restyle the window it is sitting in, live. Reading the
        // preference once at build time is why the toggle appeared to do nothing: the setting
        // was saved correctly and no window ever asked for it again.
        applySurface()
        frostObserver = Preferences.shared.$isFrosted
            .receive(on: RunLoop.main)
            .sink { [weak self] isFrosted in
                self?.applySurface(isFrosted: isFrosted)
            }
    }

    private func applySurface(isFrosted: Bool? = nil) {
        guard let frost else { return }
        OverlayChrome.applySurface(frost, isFrosted: isFrosted ?? Preferences.shared.isFrosted)
    }
}
