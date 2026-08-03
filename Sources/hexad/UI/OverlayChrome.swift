import AppKit

/// The overlay surface and its motion, in one place.
///
/// The strip, the palette and the grid all appear the same way, and before this file they each
/// built their own frost and their own fade. Three copies of a recipe is how three panels end up
/// looking subtly unlike each other — §10's "a bespoke variant is how consistency dies", applied
/// to windows rather than to controls.
enum OverlayChrome {

    private static let popKey = "hexad.pop"

    // MARK: - Surface

    /// One `NSVisualEffectView`, material `.sidebar` — the same blur every app in the family
    /// uses. Never a second one stacked inside it. `design-language.md` §3.
    static func makeFrost(cornerRadius: CGFloat) -> NSVisualEffectView {
        let frost = NSVisualEffectView()
        frost.material = .sidebar
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.wantsLayer = true
        frost.layer?.cornerRadius = cornerRadius
        frost.layer?.cornerCurve = .continuous
        frost.layer?.masksToBounds = true
        return frost
    }

    /// One switch, on or off, with no amount to choose. A surface that should not be frosted
    /// paints an **opaque fill** rather than a weaker blur — §3 again, and the reason the frost
    /// toggle has to change `state` *and* the backing colour. Setting only one of them leaves a
    /// panel that is still see-through with the switch off, which reads as a dead setting.
    static func applySurface(_ frost: NSVisualEffectView, isFrosted: Bool) {
        // An effect view built by AppKit rather than by makeFrost may not be layer-backed yet,
        // and the opaque fill lives on the layer.
        frost.wantsLayer = true
        // **R6.** Reduce Transparency wins over the preference, the way Reduce Motion already
        // does. It is an accessibility setting, not a taste one: someone who has asked the system
        // for opaque surfaces has not thereby asked every app to keep frosting anyway.
        let frosted = isFrosted && !isReducedTransparency
        frost.state = frosted ? .active : .inactive
        frost.layer?.backgroundColor = frosted ? nil : Palette.NS.bg.cgColor
    }

    /// Read live rather than cached: unlike Reduce Motion, this is a switch people flip while
    /// looking at the thing it affects, and a cached answer would need a relaunch to take.
    static var isReducedTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    // MARK: - Motion

    /// A little fade and a little scale, together: the panel pops rather than grows.
    ///
    /// The scale runs on `view`, not on the panel, because an `NSWindow` cannot scale — animating
    /// its frame would relayout the SwiftUI tree on every frame and the tiles would visibly
    /// reflow instead of the whole surface growing as one object.
    static func present(panel: NSPanel, scaling view: NSView, makeKey: Bool) {
        prepareForScaling(view)
        view.layer?.removeAnimation(forKey: popKey)

        panel.alphaValue = 0
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            // Ordering front *regardless* matters: the strip appears while another app is
            // active and must not wait to be made key, which it never will be.
            panel.orderFrontRegardless()
        }

        if let layer = view.layer {
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [Theme.Motion.Pop.from, Theme.Motion.Pop.overshoot, 1.0]
            // The overshoot lands early and settles back over the tail, so the motion decelerates
            // into place. Putting it at the midpoint reads as a wobble.
            scale.keyTimes = [0, 0.7, 1]
            scale.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            scale.duration = Theme.Motion.Pop.inDuration
            layer.add(scale, forKey: popKey)
        }

        NSAnimationContext.runAnimationGroup { context in
            // The fade finishes before the scale does. Opacity arriving first is what makes this
            // read as a pop: the panel is already legible while it is still settling.
            context.duration = Theme.Motion.Pop.inDuration * 0.7
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// The reverse, quicker. It shrinks away rather than growing — a panel that expands as it
    /// leaves reads as a mistake, and motion after the decision is just latency.
    static func dismiss(panel: NSPanel, scaling view: NSView, then: (() -> Void)? = nil) {
        prepareForScaling(view)

        if let layer = view.layer {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = Theme.Motion.Pop.to
            scale.duration = Theme.Motion.Pop.outDuration
            scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
            // Hold the end value: without this the layer snaps back to full size for the last
            // frame before the window is ordered out, which is visible as a flicker.
            scale.fillMode = .forwards
            scale.isRemovedOnCompletion = false
            layer.add(scale, forKey: popKey)
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Theme.Motion.Pop.outDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            view.layer?.removeAnimation(forKey: popKey)
            // Reset, or the next show starts from a transparent window that never fades in.
            panel.alphaValue = 1
            then?()
        })
    }

    /// A layer-backed `NSView` already anchors at its centre, so `transform.scale` scales about
    /// the middle. This only guarantees the layer exists and re-asserts the anchor, because a
    /// view that was never layer-backed would otherwise silently skip the animation.
    private static func prepareForScaling(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let centre = CGPoint(x: 0.5, y: 0.5)
        guard layer.anchorPoint != centre else { return }
        layer.anchorPoint = centre
        layer.position = CGPoint(x: view.frame.midX, y: view.frame.midY)
    }
}
