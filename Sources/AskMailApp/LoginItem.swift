import AskMailCore
import ServiceManagement

/// Registers AskMail as a macOS Login Item so it can launch at startup.
///
/// Uses `SMAppService.mainApp` (macOS 13+), the modern replacement for login-
/// item helper bundles: registration is stored per-user and the source of truth
/// is `status`, so we read it back rather than caching our own flag. Only works
/// for the signed .app bundle — the bare `swift run askmail` binary has no
/// bundle for macOS to register (see README).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turns launch-at-login on or off. No-ops when already in the desired
    /// state; throws if macOS rejects the (un)registration.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
        RollingLog.shared.log("login item \(enabled ? "enabled" : "disabled")")
    }
}
