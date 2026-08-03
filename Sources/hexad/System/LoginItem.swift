import Foundation
import ServiceManagement

/// Start hexad when the user logs in.
///
/// `SMAppService.mainApp` is the modern registration — no helper bundle, no login-items plist to
/// go stale. It is the *system* that holds this state, so `isEnabled` asks macOS rather than
/// trusting a stored preference: a user can remove a login item in System Settings, and a switch
/// that kept saying "on" afterwards would be lying.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                // Registering an already-registered app throws rather than being a no-op.
                guard SMAppService.mainApp.status != .enabled else { return true }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            RuntimeStatus.shared.trace("launch at login \(enabled ? "on" : "off")")
            return true
        } catch {
            // Most often an unsigned or quarantined build, which macOS refuses to register. Worth
            // saying rather than swallowing: the switch will spring back and the reason is here.
            RuntimeStatus.shared.trace("launch at login failed: \(error.localizedDescription)")
            return false
        }
    }
}
