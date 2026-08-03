import AppKit

/// A three-finger trackpad swipe as a way to open hexad.
///
/// **This does not use `NSEvent.swipe`, and the first version that did never fired once.**
/// Measured on this machine rather than guessed: `TrackpadThreeFingerVertSwipeGesture = 2` assigns
/// the vertical three-finger swipe to Mission Control, and `TrackpadThreeFingerHorizSwipeGesture
/// = 0` turns the horizontal one off outright. macOS therefore synthesises no swipe event for any
/// app to see. No public API can observe a gesture the window server has already claimed.
///
/// So this reads the trackpad directly, through the same private-framework route
/// `SystemSwitcher` already uses for the ⌘Tab flag: `dlopen` MultitouchSupport, resolve the
/// symbols, and degrade to "unavailable" rather than failing to launch if a future OS drops them.
/// Touch positions are API facts, established from the framework's own published interface.
///
/// The callback arrives on a private high-frequency thread — every frame, while fingers are on the
/// glass — so it does the least possible work and hands off to the main queue only when a gesture
/// actually completes.
final class TrackpadGesture: ObservableObject {

    /// One instance, because Settings has to show what it has seen and only the app delegate
    /// owns the device. Two of these would mean two callbacks and a doubled trigger.
    static let shared = TrackpadGesture()

    /// How far three fingers must travel horizontally, in normalised trackpad units (0…1 across
    /// the surface), before the switcher opens. About a tenth of the trackpad — small, because the
    /// rest of the same swipe is what does the choosing.
    private static let openThreshold: Float = 0.10
    /// How far the *other* axis may drift while opening. A diagonal is not a swipe.
    private static let crossAxisLimit: Float = 0.14
    /// Travel per selection step once the switcher is open. One unhurried swipe across the
    /// trackpad should cross a handful of windows, not one.
    private static let stepDistance: Float = 0.07

    /// Kept only so the stored preference of older builds still decodes. The gesture is now a
    /// switch: horizontal, both ways, because picking a single direction meant half of a natural
    /// two-way gesture did nothing.
    enum Direction: String, Codable, CaseIterable, Identifiable {
        case off, up, down, left, right
        var id: String { rawValue }
        var isOn: Bool { self != .off }
    }

    /// The last swipe hexad actually received, whatever its direction, and when. Settings shows
    /// this so "nothing happens" can be told apart from "macOS ate the gesture" — the two
    /// failures look identical from the trackpad.
    @Published private(set) var lastSeen: Direction?
    @Published private(set) var lastSeenAt: Date?

    /// False when the private framework is unavailable. The UI says so rather than offering a
    /// setting that cannot work.
    var isSupported: Bool { Multitouch.symbols != nil }

    /// The switcher should open — three fingers have moved far enough horizontally.
    var onOpen: () -> Void = {}
    /// Move the selection by one, while the fingers are still down. This is what makes a single
    /// swipe scrub through the list instead of a swipe-per-window.
    var onStep: (Int) -> Void = { _ in }
    /// The fingers left the glass: take the selection that is showing.
    var onCommit: () -> Void = {}

    private var devices: [Multitouch.DeviceRef] = []
    private var isEnabled = false

    /// Where the current three-finger contact started.
    private var origin: (x: Float, y: Float)?
    /// Once open, the x the next step is measured from. Advanced by one `stepDistance` each time a
    /// step fires, so a continuous drag produces evenly spaced steps rather than one per swipe.
    private var stepAnchor: Float?
    private var hasOpened = false

    var isRunning: Bool { !devices.isEmpty }

    // MARK: - Lifecycle

    func start(enabled: Bool) {
        stop()
        isEnabled = enabled
        guard enabled, let symbols = Multitouch.symbols else { return }

        // **Read the CFArray directly — do not bridge it.**
        //
        // `MTDeviceCreateList` returns a CFMutableArray of raw device handles, not of CF objects.
        // `as? [DeviceRef]` therefore fails: Swift's bridging wants elements it can retain, sees
        // pointers it cannot, and hands back nil. The guard then returned before a single device
        // was ever started — which is why the swipe never fired no matter what the touch layout
        // said. Silent, and indistinguishable from macOS eating the gesture.
        for device in Multitouch.devices(in: symbols.createDeviceList()) {
            symbols.registerCallback(device, trackpadFrameCallback)
            symbols.start(device, 0)
            devices.append(device)
        }
        RuntimeStatus.shared.trace("trackpad started · \(devices.count) device(s)")
    }

    func stop() {
        guard let symbols = Multitouch.symbols else { return }
        for device in devices { symbols.stop(device) }
        devices = []
        origin = nil
        stepAnchor = nil
        hasOpened = false
    }

    deinit { stop() }

    // MARK: - Frames

    /// Called for every frame of finger data. Stays arithmetic — see the class comment.
    fileprivate func handle(touches: [Multitouch.Touch]) {
        // Exactly three. Two is scrolling and four is Mission Control's, and claiming either
        // would make hexad the app that broke the trackpad.
        guard touches.count == 3 else {
            // Fingers gone. If this swipe opened the switcher, lifting is the choice.
            if hasOpened {
                RuntimeStatus.shared.trace("swipe lift — commit")
                let commit = onCommit
                DispatchQueue.main.async { commit() }
            }
            origin = nil
            stepAnchor = nil
            hasOpened = false
            return
        }

        let x = touches.reduce(0) { $0 + $1.normalizedX } / 3
        let y = touches.reduce(0) { $0 + $1.normalizedY } / 3

        guard let start = origin else {
            origin = (x, y)
            return
        }

        let dx = x - start.x
        let dy = y - start.y

        guard hasOpened else {
            // Horizontal, either way. Direction no longer selects *whether* it fires — only which
            // way the first step goes once it has.
            guard abs(dx) >= Self.openThreshold, abs(dy) <= Self.crossAxisLimit else { return }
            hasOpened = true
            stepAnchor = x
            RuntimeStatus.shared.trace(String(format: "swipe open dx %.3f dy %.3f", dx, dy))
            let seen: Direction = dx > 0 ? .right : .left
            let now = Date()
            let open = onOpen
            DispatchQueue.main.async { [weak self] in
                self?.lastSeen = seen
                self?.lastSeenAt = now
                open()
            }
            return
        }

        // Open already: every further `stepDistance` of travel moves the selection one place, in
        // whichever direction the fingers are currently going. Reversing mid-swipe walks back.
        guard let anchor = stepAnchor else { return }
        let travelled = x - anchor
        guard abs(travelled) >= Self.stepDistance else { return }
        let steps = Int(travelled / Self.stepDistance)
        guard steps != 0 else { return }
        stepAnchor = anchor + Float(steps) * Self.stepDistance
        RuntimeStatus.shared.trace("swipe step \(steps)")
        let step = onStep
        DispatchQueue.main.async { step(steps) }
    }
}

/// The private multitouch device API, resolved at runtime.
///
/// Same approach and same reasoning as `SystemSwitcher`'s SkyLight symbols: `dlopen` rather than
/// link, so an OS that drops them leaves the feature unavailable instead of preventing launch.
enum Multitouch {

    typealias DeviceRef = UnsafeMutableRawPointer

    /// One finger on the glass. Only the fields hexad reads are named; the rest of the frame is
    /// stepped over by size, because reading a struct by layout is what makes this fragile and
    /// naming fields hexad ignores would not make it less so.
    struct Touch {
        let normalizedX: Float
        let normalizedY: Float
    }

    /// The published shape of the framework's touch record. Offsets are what matter: position is
    /// a pair of floats at a fixed distance into each record, and the record has a fixed stride.
    private enum Layout {
        /// Bytes from the start of a touch record to its normalised position.
        ///
        /// **32, not 16.** The record opens with `int frame` (padded to 8 for the `double
        /// timestamp` that follows), then four ints — identifier, state, and two more — before the
        /// normalised vector begins. Reading at 16 lands on `identifier` and `state` and
        /// reinterprets two integers as floats, which is why the swipe never fired: the positions
        /// were garbage in the millions, so no pair of frames was ever within a threshold of each
        /// other. Silent, because a gesture that never triggers looks exactly like a gesture macOS
        /// has claimed.
        static let positionOffset = 32
        /// Bytes per touch record: 96, ending at `zDensity`.
        static let stride = 96
    }

    struct Symbols {
        let createDeviceList: @convention(c) () -> CFMutableArray?
        let registerCallback: @convention(c) (DeviceRef, @convention(c) (
            DeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32
        ) -> Int32) -> Int32
        let start: @convention(c) (DeviceRef, Int32) -> Int32
        let stop: @convention(c) (DeviceRef) -> Int32
    }

    static let symbols: Symbols? = {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework"
            + "/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY),
              let list = dlsym(handle, "MTDeviceCreateList"),
              let register = dlsym(handle, "MTRegisterContactFrameCallback"),
              let start = dlsym(handle, "MTDeviceStart"),
              let stop = dlsym(handle, "MTDeviceStop")
        else { return nil }

        return Symbols(
            createDeviceList: unsafeBitCast(list, to: (@convention(c) () -> CFMutableArray?).self),
            registerCallback: unsafeBitCast(register, to: (@convention(c) (
                DeviceRef, @convention(c) (
                    DeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32
                ) -> Int32
            ) -> Int32).self),
            start: unsafeBitCast(start, to: (@convention(c) (DeviceRef, Int32) -> Int32).self),
            stop: unsafeBitCast(stop, to: (@convention(c) (DeviceRef) -> Int32).self))
    }()

    /// Pull the device handles out of the CFArray by index.
    ///
    /// The array holds raw pointers rather than CF objects, so `CFArrayGetValueAtIndex` is the only
    /// correct way in — a Swift bridge cast silently yields nil.
    static func devices(in list: CFMutableArray?) -> [DeviceRef] {
        guard let list else { return [] }
        return (0..<CFArrayGetCount(list)).compactMap { index in
            guard let raw = CFArrayGetValueAtIndex(list, index) else { return nil }
            return UnsafeMutableRawPointer(mutating: raw)
        }
    }

    /// Read the touches out of one frame.
    ///
    /// Anything outside 0…1 is dropped rather than trusted. This is a struct layout read by offset,
    /// so it is the one part of hexad that a future OS can silently invalidate — and a wrong offset
    /// does not crash, it yields plausible-looking nonsense. A normalised position that is not
    /// normalised is the signal that the layout moved, and dropping those frames turns a subtly
    /// broken gesture into one that simply never fires, which `isLayoutValid` can then report.
    static func touches(from raw: UnsafeMutableRawPointer?, count: Int32) -> [Touch] {
        guard let raw, count > 0 else { return [] }
        return (0..<Int(count)).compactMap { index in
            let base = raw.advanced(by: index * Layout.stride + Layout.positionOffset)
            let x = base.loadUnaligned(as: Float.self)
            let y = base.loadUnaligned(fromByteOffset: 4, as: Float.self)
            guard x.isFinite, y.isFinite, (-0.1...1.1).contains(x), (-0.1...1.1).contains(y)
            else {
                layoutLooksWrong = true
                return nil
            }
            return Touch(normalizedX: x, normalizedY: y)
        }
    }

    /// Set the first time a frame arrives with positions outside the normalised range. Surfaced in
    /// Settings, so "the swipe does nothing" has an answer other than a shrug.
    nonisolated(unsafe) private(set) static var layoutLooksWrong = false
}

/// A C function pointer, so it cannot capture. The shared instance is the only receiver, which is
/// why `TrackpadGesture` is a singleton rather than merely convenient as one.
private func trackpadFrameCallback(device: Multitouch.DeviceRef?,
                                   data: UnsafeMutableRawPointer?,
                                   count: Int32,
                                   timestamp: Double,
                                   frame: Int32) -> Int32 {
    TrackpadGesture.shared.handle(touches: Multitouch.touches(from: data, count: count))
    return 0
}
