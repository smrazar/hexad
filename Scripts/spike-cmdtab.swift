// hexad Phase 0 spike — event tap interception.
//
// Three jobs:
//   --watch            swallow nothing, print every key the tap sees. Diagnoses who is eating what.
//   --key opt-tab      swallow a chosen combo. Proves the tap plumbing works, end to end.
//   --key cmd-tab      the gate question: does swallowing suppress the macOS switcher?
//   --private          also disable the system switcher via the private SkyLight call.
//   --read-only        report the symbolic-hotkey flag and exit. --restore forces it back on.
//
// ⌘Tab is special because it is a WindowServer symbolic hotkey. Any other combo is an ordinary
// key event, so swallowing it proves the mechanism but NOT the ⌘Tab question. Both matter.
//
// Safety: hard timeout, and the symbolic-hotkey flag is restored on every exit path.
// Throwaway. It proves facts; it does not become the app.
//
//   swiftc -O spike-cmdtab.swift -o spike-cmdtab

import ApplicationServices
import Cocoa

var RUN_SECONDS = 25.0
let SHK_COMMAND_TAB: Int32 = 71
let SHK_COMMAND_SHIFT_TAB: Int32 = 72

// MARK: - Window sampling
//
// Synthesised keystrokes never trigger the switcher (BUGS.md B2), but a real one from a human does.
// So the human presses the key and this samples the window list — the verdict is measured rather
// than eyeballed. Titles are never read; that would need Screen Recording.

struct Win: Hashable {
    let number: Int
    let owner: String
    let layer: Int
    let width: Int
    let height: Int
    var describe: String { "\(owner) [layer \(layer)] \(width)×\(height) #\(number)" }
    /// The macOS switcher is drawn by Dock, above normal windows, and is large.
    var looksLikeSwitcher: Bool { owner == "Dock" && layer > 0 && width > 200 && height > 60 }
}

func snapshotWindows() -> Set<Win> {
    guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] else { return [] }
    var out = Set<Win>()
    for w in raw {
        guard let number = w[kCGWindowNumber as String] as? Int,
              let owner = w[kCGWindowOwnerName as String] as? String,
              let layer = w[kCGWindowLayer as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let width = b["Width"] as? Double, let height = b["Height"] as? Double
        else { continue }
        out.insert(Win(number: number, owner: owner, layer: layer,
                       width: Int(width), height: Int(height)))
    }
    return out
}

// MARK: - Combos

struct Combo {
    let name: String
    let display: String
    let keycode: Int64
    let required: CGEventFlags
    /// Modifiers that must be absent, so ⌥Tab does not also match ⌘⌥Tab.
    let forbidden: CGEventFlags

    func matches(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventKeycode) == keycode else { return false }
        let flags = event.flags
        guard flags.contains(required) else { return false }
        return !flags.contains(where: forbidden)
    }

    /// True if the combo is the system switcher, which needs the symbolic-hotkey machinery.
    var isSystemSwitcher: Bool { keycode == 48 && required.contains(.maskCommand) }
}

extension CGEventFlags {
    func contains(where other: CGEventFlags) -> Bool { !self.intersection(other).isEmpty }
}

let COMBOS: [Combo] = [
    Combo(name: "cmd-tab", display: "⌘Tab", keycode: 48,
          required: .maskCommand, forbidden: [.maskAlternate, .maskControl]),
    Combo(name: "opt-tab", display: "⌥Tab", keycode: 48,
          required: .maskAlternate, forbidden: [.maskCommand, .maskControl]),
    Combo(name: "ctrl-tab", display: "⌃Tab", keycode: 48,
          required: .maskControl, forbidden: [.maskCommand, .maskAlternate]),
    Combo(name: "opt-space", display: "⌥Space", keycode: 49,
          required: .maskAlternate, forbidden: [.maskCommand, .maskControl]),
    Combo(name: "f13", display: "F13", keycode: 105, required: [], forbidden: []),
]

func describeFlags(_ f: CGEventFlags) -> String {
    var parts: [String] = []
    if f.contains(.maskCommand) { parts.append("⌘") }
    if f.contains(.maskAlternate) { parts.append("⌥") }
    if f.contains(.maskControl) { parts.append("⌃") }
    if f.contains(.maskShift) { parts.append("⇧") }
    if f.contains(.maskSecondaryFn) { parts.append("fn") }
    return parts.isEmpty ? "—" : parts.joined()
}

// MARK: - Private SkyLight symbols, resolved at runtime rather than linked

typealias SetSHKEnabledFn = @convention(c) (Int32, Bool) -> Int32
typealias IsSHKEnabledFn = @convention(c) (Int32) -> Bool

struct SymbolicHotKeys {
    let set: SetSHKEnabledFn
    let isEnabled: IsSHKEnabledFn

    static func load() -> SymbolicHotKeys? {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY),
              let setSym = dlsym(handle, "CGSSetSymbolicHotKeyEnabled"),
              let isSym = dlsym(handle, "CGSIsSymbolicHotKeyEnabled")
        else { return nil }
        return SymbolicHotKeys(set: unsafeBitCast(setSym, to: SetSHKEnabledFn.self),
                               isEnabled: unsafeBitCast(isSym, to: IsSHKEnabledFn.self))
    }
}

// MARK: - Global state (a C callback cannot capture)

final class SpikeState {
    var combo: Combo = COMBOS[0]
    var watchMode = false
    var matched = 0
    var totalKeys = 0
    var tapDisabledEvents = 0
    var shk: SymbolicHotKeys?
    var shkOriginalCommandTab: Bool?
    var shkOriginalCommandShiftTab: Bool?
    var tap: CFMachPort?
    var baselineWindows = Set<Win>()
    var newWindows = Set<Win>()
    /// Counts keys seen during the synthetic self-test, so "saw nothing" can be told apart
    /// from "nobody typed". Synthesised events do reach session taps — only WindowServer
    /// symbolic hotkeys ignore them (BUGS.md B2), and F13 is not one.
    var inSelfTest = false
    var selfTestSeen = 0
}
let state = SpikeState()

func restoreSymbolicHotKeys() {
    guard let shk = state.shk else { return }
    if let original = state.shkOriginalCommandTab {
        _ = shk.set(SHK_COMMAND_TAB, original)
        state.shkOriginalCommandTab = nil
        print("  restored ⌘Tab symbolic hotkey to enabled=\(original)")
    }
    if let original = state.shkOriginalCommandShiftTab {
        _ = shk.set(SHK_COMMAND_SHIFT_TAB, original)
        state.shkOriginalCommandShiftTab = nil
    }
}

// MARK: - Conflict detection

let BLOCKING_APPS = ["AltTab", "rcmd", "DockDoor", "Contexts", "Witch", "LaunchOS"]
let SUSPECT_APPS = ["Superkey", "Karabiner-Elements", "BetterTouchTool", "Hammerspoon",
                    "Multitouch", "Loop", "Swish", "1Piece", "LinearMouse"]

func running(_ names: [String]) -> [String] {
    let live = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }
    return names.filter { name in live.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
}

// MARK: - The tap callback. Classify and forward, nothing else.

func tapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        state.tapDisabledEvents += 1
        if let tap = state.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        print("  ! tap disabled, re-armed")
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }

    if state.inSelfTest {
        state.selfTestSeen += 1
        return nil   // swallow the probe so it never reaches an app
    }

    state.totalKeys += 1
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let mods = describeFlags(event.flags)

    if state.watchMode {
        print("  saw  \(mods) keycode \(code)")
        return Unmanaged.passUnretained(event)   // watch mode never swallows
    }

    guard state.combo.matches(event) else { return Unmanaged.passUnretained(event) }
    state.matched += 1
    print("  saw \(state.combo.display) (#\(state.matched)) — swallowing")
    return nil
}

// MARK: - Main

var argv = Array(CommandLine.arguments.dropFirst())
let flags = Set(argv.filter { $0.hasPrefix("--") })

if let i = argv.firstIndex(of: "--key"), i + 1 < argv.count {
    let wanted = argv[i + 1]
    guard let found = COMBOS.first(where: { $0.name == wanted }) else {
        print("unknown key '\(wanted)'. Options: \(COMBOS.map(\.name).joined(separator: ", "))")
        exit(2)
    }
    state.combo = found
}
state.watchMode = flags.contains("--watch")

if let i = argv.firstIndex(of: "--seconds"), i + 1 < argv.count, let n = Double(argv[i + 1]) {
    RUN_SECONDS = max(5, min(300, n))
}

state.shk = SymbolicHotKeys.load()

print("hexad Phase 0 spike")
print(String(repeating: "─", count: 60))

if let shk = state.shk {
    let enabled = shk.isEnabled(SHK_COMMAND_TAB)
    print("SkyLight private symbols: available")
    print("system ⌘Tab symbolic hotkey enabled: \(enabled)")
    if flags.contains("--restore") {
        _ = shk.set(SHK_COMMAND_TAB, true)
        _ = shk.set(SHK_COMMAND_SHIFT_TAB, true)
        print("  forced both back to enabled=true")
        exit(0)
    }
    if !enabled {
        let owners = running(BLOCKING_APPS)
        print(owners.isEmpty
            ? "  ^^ NOT enabled and no known switcher running — likely leaked. Use --restore."
            : "  ^^ held by: \(owners.joined(separator: ", "))")
    }
} else {
    print("SkyLight private symbols: UNAVAILABLE on this OS")
}

if flags.contains("--read-only") { exit(0) }

guard AXIsProcessTrusted() else {
    print("\nBLOCKED: not trusted for Accessibility.")
    print("Grant it to the terminal running this, in:")
    print("  System Settings ▸ Privacy & Security ▸ Accessibility")
    exit(1)
}
print("Accessibility: trusted")

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
    eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
    callback: tapCallback, userInfo: nil
) else {
    print("BLOCKED: tapCreate returned nil despite Accessibility being granted.")
    exit(1)
}
state.tap = tap
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("event tap: installed (.cgSessionEventTap, head, defaultTap)")

// Prove the tap is actually in the event path, before asking a human to press anything.
// F13 is used because it does nothing on a stock system, and it is swallowed anyway.
func runSelfTest() -> Bool {
    state.inSelfTest = true
    defer { state.inSelfTest = false; state.totalKeys = 0 }
    if let src = CGEventSource(stateID: .hidSystemState) {
        for _ in 0..<2 {
            CGEvent(keyboardEventSource: src, virtualKey: 105, keyDown: true)?
                .post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 105, keyDown: false)?
                .post(tap: .cghidEventTap)
        }
    }
    // Drain the FULL window rather than returning on the first hit — probes that land after
    // inSelfTest clears would be counted as real keypresses and fake a result.
    let deadline = Date().addingTimeInterval(0.6)
    while Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.02, true)
    }
    return state.selfTestSeen > 0
}

let tapIsLive = runSelfTest()
print("tap self-test: \(tapIsLive ? "PASS — tap is in the event path" : "FAIL — tap sees nothing")")
if !tapIsLive {
    print("  The tap installed but receives no events. Grant Accessibility to this terminal in")
    print("  System Settings ▸ Privacy & Security ▸ Accessibility, then rerun.")
    restoreSymbolicHotKeys()
    exit(1)
}

// Only ⌘Tab needs a clear field. Any other combo is an ordinary key event.
if !state.watchMode && state.combo.isSystemSwitcher {
    let conflicts = running(BLOCKING_APPS)
    if !conflicts.isEmpty {
        print("\nSTOP: \(conflicts.joined(separator: ", ")) already owns ⌘Tab.")
        print("This would measure that, not hexad. Quit and rerun:")
        for app in conflicts { print("  osascript -e 'quit app \"\(app)\"'") }
        print("\nOr test the tap mechanism on a free key instead:")
        print("  ./spike-cmdtab --key opt-tab")
        exit(1)
    }
}

let suspects = running(SUSPECT_APPS)
if !suspects.isEmpty {
    print("note: \(suspects.joined(separator: ", ")) running — may sit in the event path.")
}

if flags.contains("--private") {
    if let shk = state.shk {
        state.shkOriginalCommandTab = shk.isEnabled(SHK_COMMAND_TAB)
        state.shkOriginalCommandShiftTab = shk.isEnabled(SHK_COMMAND_SHIFT_TAB)
        _ = shk.set(SHK_COMMAND_TAB, false)
        _ = shk.set(SHK_COMMAND_SHIFT_TAB, false)
        print("private fallback: system ⌘Tab DISABLED (restored on exit)")
    }
}

atexit { restoreSymbolicHotKeys() }
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        print("\n  caught signal \(sig)")
        restoreSymbolicHotKeys()
        exit(0)
    }
    src.resume()
}

print("")
if state.watchMode {
    print("WATCH MODE — nothing is swallowed. Press ⌘Tab, ⌥Tab, anything.")
    print("If a combo never prints here, something upstream ate it before the tap.")
} else {
    print("NOW: press \(state.combo.display) a few times.")
    if state.combo.isSystemSwitcher {
        print("WATCH: does the macOS app switcher still appear on screen?")
    } else {
        print("EXPECT: \(state.combo.display) should do nothing at all — it is being swallowed.")
    }
}
print("Auto-exits in \(Int(RUN_SECONDS))s. Ctrl-C is safe.")
print(String(repeating: "─", count: 60))

// Sample the window list throughout, so an appearing switcher is recorded rather than eyeballed.
state.baselineWindows = snapshotWindows()
let sampler = Timer(timeInterval: 0.12, repeats: true) { _ in
    let fresh = snapshotWindows().subtracting(state.baselineWindows).subtracting(state.newWindows)
    for w in fresh {
        state.newWindows.insert(w)
        if w.looksLikeSwitcher {
            print("  >> SWITCHER APPEARED: \(w.describe)")
        }
    }
}
RunLoop.current.add(sampler, forMode: .common)

DispatchQueue.main.asyncAfter(deadline: .now() + RUN_SECONDS) {
    print(String(repeating: "─", count: 60))
    print("VERDICT")
    print("  total keyDown events seen: \(state.totalKeys)")
    print("  tap auto-disable events:   \(state.tapDisabledEvents)")

    if state.watchMode {
        print("\n  Watch mode. Any combo you pressed that did not print above")
        print("  was consumed before reaching a session tap.")
    } else {
        print("  \(state.combo.display) matched and swallowed: \(state.matched)")
        if state.totalKeys == 0 {
            // The self-test already proved the tap works, so this is not a tap problem.
            print("\n  NO RESULT — the tap is live (self-test passed) but no key was pressed")
            print("  during the run. Nobody typed. Rerun and press ⌘Tab while it is running.")
        } else if state.matched == 0 {
            print("\n  The tap saw keys but never \(state.combo.display).")
            print("  Something upstream is consuming it. Rerun with --watch to see what does arrive.")
        } else if state.combo.isSystemSwitcher {
            let hits = state.newWindows.filter(\.looksLikeSwitcher)
            print("  switcher windows detected:  \(hits.count)")
            for w in hits { print("    \(w.describe)") }
            print("")
            if hits.isEmpty {
                print("  MEASURED: swallowed \(state.matched) ⌘Tab press(es), and the macOS switcher")
                print("  never appeared. Swallowing at the tap is ENOUGH — no private API needed.")
            } else {
                print("  MEASURED: swallowed \(state.matched) ⌘Tab press(es) but the macOS switcher")
                print("  STILL APPEARED. Swallowing is NOT enough. hexad needs")
                print("  CGSSetSymbolicHotKeyEnabled(71, false), plus the launch-time repair in B1.")
                print("  Confirm with: ./spike-cmdtab --private")
            }
        } else {
            print("\n  Tap plumbing works: \(state.combo.display) reached the tap and was swallowed.")
            print("  This does NOT answer the ⌘Tab question — ⌘Tab is a symbolic hotkey.")
        }
    }
    restoreSymbolicHotKeys()
    print(String(repeating: "─", count: 60))
    exit(0)
}

CFRunLoopRun()
