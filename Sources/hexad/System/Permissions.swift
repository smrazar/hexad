import AppKit
import ApplicationServices

/// hexad needs exactly one permission in v1: Accessibility.
///
/// It reads window titles through the Accessibility API rather than `CGWindowListCopyWindowInfo`,
/// whose `kCGWindowName` is nil without Screen Recording. Reading titles through Accessibility
/// is why hexad needs one permission rather than two. Screen Recording arrives only with window
/// previews, and only if the user turns them on.
enum Permissions {

    static var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show its own Accessibility prompt. Only from an explicit user action —
    /// an unprompted system dialog on first launch is how an app gets denied and dismissed.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Opens the exact pane, not the top of System Settings.
    static func openAccessibilitySettings() {
        open("Privacy_Accessibility")
    }

    // MARK: - Screen Recording

    /// Only ever needed for window previews, and only once the user turns them on. v1 asks for
    /// one permission; this is the second, and it stays optional on purpose — PLAN.md §2.
    static var isScreenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt. macOS only shows it once per app version, so a user who
    /// declines has to go to System Settings — which is why the UI offers that route too.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        open("Privacy_ScreenCapture")
    }

    private static func open(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
