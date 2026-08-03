// hexad Phase 0 spike, automated — does swallowing ⌘Tab at a session tap suppress the macOS switcher?
//
// The manual version needs a human to press ⌘Tab and watch the screen. This one synthesises the
// keystroke and detects the switcher by looking for the window it draws, so the answer is measured
// rather than reported. Runs as a controlled experiment:
//
//   Phase A (control)  no tap installed  -> the switcher SHOULD appear. Proves detection works.
//   Phase B (test)     tap swallowing    -> if the switcher still appears, swallowing is not enough.
//
// Escape is sent before Command is released, so neither phase actually switches window.
//
//   swiftc -O spike-auto.swift -o spike-auto && ./spike-auto

import ApplicationServices
import Cocoa

let KEY_TAB: CGKeyCode = 48
let KEY_ESC: CGKeyCode = 53
let KEY_CMD: CGKeyCode = 55
let HOLD_MS = 450

// MARK: - Window snapshots

struct Win: Hashable {
    let number: Int
    let owner: String
    let layer: Int
    let width: Int
    let height: Int

    var describe: String { "\(owner) [layer \(layer)] \(width)×\(height) #\(number)" }
}

/// Every on-screen window. Titles are deliberately not read — that would need Screen Recording,
/// which is the permission hexad exists to avoid.
func snapshot() -> Set<Win> {
    // No .excludeDesktopElements — the switcher may well be classed as one.
    let opts: CGWindowListOption = [.optionOnScreenOnly]
    guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    var out = Set<Win>()
    for w in raw {
        guard let number = w[kCGWindowNumber as String] as? Int,
              let owner = w[kCGWindowOwnerName as String] as? String,
              let layer = w[kCGWindowLayer as String] as? Int,
              let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
              let width = boundsDict["Width"] as? Double,
              let height = boundsDict["Height"] as? Double
        else { continue }
        out.insert(Win(number: number, owner: owner, layer: layer,
                       width: Int(width), height: Int(height)))
    }
    return out
}

// MARK: - Synthetic keystrokes

func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
    guard let src = CGEventSource(stateID: .hidSystemState),
          let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
    else { return }
    ev.flags = flags
    ev.post(tap: .cghidEventTap)
}

/// Hold ⌘, tap Tab, sample what appeared, then cancel with Escape so nothing actually switches.
func pressCommandTabAndSample() -> Set<Win> {
    let before = snapshot()

    post(KEY_CMD, down: true, flags: .maskCommand)
    usleep(60_000)
    post(KEY_TAB, down: true, flags: .maskCommand)
    post(KEY_TAB, down: false, flags: .maskCommand)

    usleep(UInt32(HOLD_MS) * 1000)
    let during = snapshot()

    // Cancel rather than commit — Escape while Command is still held.
    post(KEY_ESC, down: true, flags: .maskCommand)
    post(KEY_ESC, down: false, flags: .maskCommand)
    usleep(40_000)
    post(KEY_CMD, down: false, flags: [])
    usleep(150_000)

    return during.subtracting(before)
}

// MARK: - The tap

final class TapState {
    var swallowed = 0
    var tap: CFMachPort?
}
let tapState = TapState()

func swallowCommandTab(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = tapState.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    guard code == Int64(KEY_TAB), event.flags.contains(.maskCommand) else {
        return Unmanaged.passUnretained(event)
    }
    tapState.swallowed += 1
    return nil     // swallow. the entire question.
}

func installTap() -> Bool {
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
        callback: swallowCommandTab,
        userInfo: nil
    ) else { return false }
    tapState.tap = tap
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

/// Let the runloop breathe so tap callbacks actually fire while we sleep.
func spin(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.02, true)
    }
}

// MARK: - Main

print("hexad Phase 0 spike (automated)")
print(String(repeating: "─", count: 62))

guard AXIsProcessTrusted() else {
    print("BLOCKED: not trusted for Accessibility. Grant it to this terminal and re-run.")
    exit(1)
}

// ---------- Phase A: control ----------
print("\nPHASE A — control, no tap. The system switcher should appear.")
let controlNew = pressCommandTabAndSample()
if controlNew.isEmpty {
    print("  no new windows appeared")
} else {
    for w in controlNew.sorted(by: { $0.number < $1.number }) { print("  + \(w.describe)") }
}

// The macOS switcher is drawn by the Dock process at a raised window layer.
func looksLikeSwitcher(_ s: Set<Win>) -> [Win] {
    s.filter { $0.owner == "Dock" && $0.layer > 0 && $0.width > 200 && $0.height > 60 }
}
let controlHits = looksLikeSwitcher(controlNew)
print("  switcher-shaped windows: \(controlHits.count)")

guard !controlHits.isEmpty else {
    print("""

    INCONCLUSIVE — the control phase never saw the switcher, so detection is not working
    and Phase B would prove nothing. Falls back to the manual spike:
      ./spike-cmdtab   then press ⌘Tab and watch the screen.
    """)
    exit(2)
}
print("  detection works.")

// ---------- Phase B: test ----------
print("\nPHASE B — tap installed, swallowing ⌘Tab.")
guard installTap() else {
    print("BLOCKED: tapCreate returned nil.")
    exit(1)
}
spin(0.3)

let before = snapshot()
post(KEY_CMD, down: true, flags: .maskCommand)
spin(0.06)
post(KEY_TAB, down: true, flags: .maskCommand)
post(KEY_TAB, down: false, flags: .maskCommand)
spin(Double(HOLD_MS) / 1000.0)
let testNew = snapshot().subtracting(before)
post(KEY_ESC, down: true, flags: .maskCommand)
post(KEY_ESC, down: false, flags: .maskCommand)
spin(0.04)
post(KEY_CMD, down: false, flags: [])
spin(0.2)

if testNew.isEmpty {
    print("  no new windows appeared")
} else {
    for w in testNew.sorted(by: { $0.number < $1.number }) { print("  + \(w.describe)") }
}
let testHits = looksLikeSwitcher(testNew)
print("  switcher-shaped windows: \(testHits.count)")
print("  events swallowed by the tap: \(tapState.swallowed)")

// ---------- Verdict ----------
print("\n" + String(repeating: "─", count: 62))
print("VERDICT")
if tapState.swallowed == 0 {
    print("  The tap never saw ⌘Tab — it is handled before session taps.")
    print("  Swallowing cannot work. hexad needs CGSSetSymbolicHotKeyEnabled.")
} else if testHits.isEmpty {
    print("  Swallowing at the tap IS enough. The switcher appeared without the tap")
    print("  and did not appear with it. No private API needed for ⌘Tab.")
} else {
    print("  The tap swallowed \(tapState.swallowed) event(s) but the switcher STILL appeared.")
    print("  Swallowing is not enough. hexad needs CGSSetSymbolicHotKeyEnabled(71, false),")
    print("  with the restore-on-every-exit-path handling already in the plan.")
}
print(String(repeating: "─", count: 62))
