import AppKit
import SwiftUI

/// Middle-click on a tile, the way every tab strip on the platform closes a tab.
///
/// SwiftUI has no gesture for the middle button — `onTapGesture` is the left button only — so this
/// is one `NSView` that overrides `otherMouseUp` and forwards it. Placed as an overlay so it never
/// takes the left-click and hover handling the tile already has.
struct MiddleClickCatcher: NSViewRepresentable {

    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: () -> Void = {}

        /// Only the middle button is claimed. Everything else falls through to the SwiftUI view
        /// underneath, which is what keeps hover and left-click working.
        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2 else {
                super.otherMouseUp(with: event)
                return
            }
            action()
        }

        /// Hit-test only for the middle button. Returning self unconditionally would swallow every
        /// left click on the tile — the tile would stop being clickable at all.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                return super.hitTest(point)
            default:
                return nil
            }
        }
    }
}

extension View {
    /// Run `action` when this view is middle-clicked.
    func onMiddleClick(perform action: @escaping () -> Void) -> some View {
        overlay(MiddleClickCatcher(action: action))
    }

    /// Apply modifiers only when a condition holds.
    ///
    /// Used for the grid's drag-between-displays, which must not attach `onDrag` at all on a
    /// one-display machine — a drag that can go nowhere is worse than no drag, because the card
    /// lifts off and then refuses.
    ///
    /// The usual caveat applies: switching the branch changes the view's identity and resets its
    /// state. Safe here because the condition is "how many displays are attached", which cannot
    /// change without the grid being rebuilt anyway.
    @ViewBuilder
    func ifCondition<Modified: View>(_ condition: Bool,
                                     _ transform: (Self) -> Modified) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
