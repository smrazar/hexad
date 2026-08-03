import AppKit

/// The keyboard tap.
///
/// PLAN.md §11 gives this callback a **1ms budget**, and that is not a style preference:
/// macOS silently disables an event tap whose callback runs long, with no error anywhere. So
/// this file decides one thing — swallow or pass — and does no work. Everything the decision
/// implies runs on the next main-loop turn.
///
/// The tap is added to the main run loop, so `handle` is already on the main thread.
final class HotkeyTap {

    /// Returns true when the event was consumed and must not reach the focused app.
    typealias Handler = (CGEventType, CGEvent) -> Bool

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Fails when Accessibility has not been granted. The caller must tell the user that, not
    /// retry silently — a switcher that does nothing and explains nothing is the complaint
    /// this app exists to answer.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask),
                                           callback: hotkeyTapCallback,
                                           userInfo: refcon)
        else { return false }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tap = port
        source = runLoopSource
        return true
    }

    func stop() {
        guard let tap, let source else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = nil
        self.source = nil
    }

    var isRunning: Bool { tap != nil }

    /// macOS disables a tap it thinks is too slow and tells nobody. Re-enabling here is why
    /// the switcher does not quietly stop working after a system hiccup — PLAN.md §7 makes it
    /// Phase 3's exit criterion.
    fileprivate func reenableAfterTimeout() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("hexad: event tap was disabled by the system and has been re-enabled")
    }

    fileprivate func decide(_ type: CGEventType, _ event: CGEvent) -> Bool {
        handler(type, event)
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy,
                               type: CGEventType,
                               event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenableAfterTimeout()
        return nil
    }

    return tap.decide(type, event) ? nil : Unmanaged.passUnretained(event)
}
