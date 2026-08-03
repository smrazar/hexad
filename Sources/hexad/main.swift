import AppKit

// --self-check runs in the shipping binary and exits non-zero on failure, so the build script
// can fail on it. See SelfCheck.swift.
if CommandLine.arguments.contains("--self-check") {
    // --bench measures PLAN.md §11's two budgets rather than checking correctness. Deliberately
    // not part of the build gate: a timing run on a loaded machine fails for reasons that have
    // nothing to do with the code.
    if CommandLine.arguments.contains("--bench") {
        let (_, isWithin) = Bench.run()
        exit(isWithin ? 0 : 1)
    }

    let failures = SelfCheck.runAll()
    if failures.isEmpty {
        print("hexad self-check: PASS")
        exit(0)
    }
    for failure in failures {
        print("FAIL  \(failure.check): \(failure.detail)")
    }
    print("hexad self-check: \(failures.count) failure(s)")
    exit(1)
}

// --system-switcher reports and controls the macOS ⌘Tab state from the terminal, which is the
// documented recovery path if hexad is ever uninstalled while holding it off.
if CommandLine.arguments.contains("--system-switcher") {
    if CommandLine.arguments.contains("--restore") {
        let ok = SystemSwitcher.restore()
        print("system ⌘Tab restored: \(ok)")
        exit(ok ? 0 : 1)
    }
    print("system ⌘Tab: \(SystemSwitcher.statusDescription)")
    exit(0)
}

// --trackpad-probe prints raw multitouch frames so the struct layout can be *measured* rather
// than assumed. The touch record is read by byte offset, and a wrong offset does not crash — it
// yields plausible nonsense and a gesture that silently never fires. This dumps the candidate
// offsets for one frame at a time so the right one can be read off the screen: normalised position
// is the pair of floats that stays inside 0…1 and changes as the finger moves.
if CommandLine.arguments.contains("--trackpad-probe") {
    guard let symbols = Multitouch.symbols else {
        print("trackpad: MultitouchSupport unavailable on this OS")
        exit(1)
    }
    let devices = Multitouch.devices(in: symbols.createDeviceList())
    guard !devices.isEmpty else {
        print("trackpad: no multitouch devices — an external mouse has no touch surface")
        exit(1)
    }
    print("trackpad: \(devices.count) device(s). Put THREE fingers on the trackpad and move them.")
    print("trackpad: each line is one touch — offset 16 vs 32, and the record stride.")
    print("trackpad: ctrl-C when done.\n")
    for device in devices {
        symbols.registerCallback(device, trackpadProbeCallback)
        symbols.start(device, 0)
    }
    RunLoop.main.run()
}

// --dump-windows is Phase 2's exit criterion: the list hexad would show, printed, so it can be
// checked against reality across Spaces and minimized windows without any UI in the way.
if CommandLine.arguments.contains("--dump-windows") {
    guard Permissions.isAccessibilityGranted else {
        print("Accessibility is not granted — the window list is empty by definition.")
        print("Grant it to this binary's parent app, then run again.")
        exit(1)
    }
    let store = WindowStore()
    store.rebuild()

    // --why explains the list instead of only printing it: which apps AX refused, which windows
    // were dropped and by which rule. "My windows are missing" has half a dozen causes that look
    // identical from outside.
    if CommandLine.arguments.contains("--why") {
        print(store.diagnose())
        print("")
    }

    let items = store.snapshot()
    print("\(items.count) window(s), most-recently-used first:")
    for (offset, item) in items.enumerated() {
        let flag = item.isMinimized ? " [minimized]" : ""
        print(String(format: "%3d  %-24@ %@%@",
                     offset, item.appName as NSString, item.displayTitle as NSString,
                     flag as NSString))
    }
    exit(0)
}

// --demo-settings opens the Settings window on its own, with no status item and no event tap.
//
// Running the full app from the terminal to look at a window would install a second tap
// competing with the installed copy for ⌘Tab, which is a good way to spend an afternoon
// debugging a conflict that only exists during debugging.
var demoSettingsWindow: AppWindow?
if CommandLine.arguments.contains("--demo-settings") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Preferences.shared.applyAppearance()
    demoSettingsWindow = AppWindow(title: "hexad Settings",
                                   size: NSSize(width: 720, height: 520)) { SettingsView() }
    demoSettingsWindow?.show()
    app.run()
}

// --demo-onboarding runs the welcome tour without touching the "already onboarded" flag.
//
// The tour is the one surface that is otherwise unreachable once it has been completed, short of
// wiping the preferences domain — which means it went unlooked-at for several rounds while it
// grew from three steps to five. A flag costs nothing and makes it checkable on demand.
var demoOnboarding: AppWindow?
if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-onboarding") }) {
    // --demo-onboarding=3 opens straight at that step. Zero-based, clamped in OnboardingView.
    let startStep = Int(flag.split(separator: "=").last ?? "") ?? 0
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Preferences.shared.applyAppearance()
    demoOnboarding = AppWindow(title: "Welcome to hexad",
                               size: NSSize(width: 640, height: 660)) {
        OnboardingView(startStep: startStep, onFinish: { exit(0) })
    }
    demoOnboarding?.show()
    app.activate()
    app.run()
}

// --demo-palette opens the search palette against the real window list, with no event tap.
var demoPalette: PaletteController?
if CommandLine.arguments.contains("--demo-palette") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Preferences.shared.applyAppearance()
    let store = WindowStore()
    store.rebuild()
    demoPalette = PaletteController(store: store)
    demoPalette?.open()
    app.run()
}

// --demo-grid opens the grid against the real window list, with no event tap.
var demoGrid: GridController?
if CommandLine.arguments.contains("--demo-grid") {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Preferences.shared.applyAppearance()
    let store = WindowStore()
    store.rebuild()
    demoGrid = GridController(store: store)
    demoGrid?.open()
    app.run()
}

// --demo-overlay draws the strip with the real window list and quits.
//
// The ⌘Tab path itself cannot be automated — WindowServer hotkeys ignore synthesised events,
// see docs/STATUS.md — but that is no reason for the *drawing* to go unlooked-at until a user
// presses a key. This renders it on demand so it can be screenshotted and checked.
if CommandLine.arguments.contains("--demo-overlay") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let store = WindowStore()
    store.rebuild()
    let items = store.snapshot()
    guard !items.isEmpty else {
        print("no windows to draw — is Accessibility granted to this terminal?")
        exit(1)
    }

    let overlay = StripOverlay()
    overlay.prepare()
    overlay.show(items: items, selected: min(1, items.count - 1),
                 shortcutLabel: Shortcut.active.label)
    print("drawing \(items.count) window(s) for 4s")
    Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in exit(0) }
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar utility: no Dock icon, no main menu.
app.setActivationPolicy(.accessory)
app.run()

/// Prints one line per touch, showing both candidate offsets side by side.
private func trackpadProbeCallback(device: Multitouch.DeviceRef?,
                                   data: UnsafeMutableRawPointer?,
                                   count: Int32,
                                   timestamp: Double,
                                   frame: Int32) -> Int32 {
    guard let data, count > 0 else { return 0 }
    // Only report three-finger frames — that is the gesture in question, and every other frame is
    // noise that scrolls the useful lines away.
    guard count == 3 else { return 0 }
    for index in 0..<Int(count) {
        let record = data.advanced(by: index * 96)
        func floats(at offset: Int) -> String {
            let x = record.loadUnaligned(fromByteOffset: offset, as: Float.self)
            let y = record.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
            return String(format: "%+10.4f,%+10.4f", x, y)
        }
        print("touch \(index)  @16 \(floats(at: 16))   @32 \(floats(at: 32))")
    }
    print("---")
    return 0
}
