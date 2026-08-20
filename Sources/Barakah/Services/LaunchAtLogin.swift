import Foundation
import ServiceManagement
import OSLog

/// Thin wrapper over `SMAppService` for the launch-at-login toggle.
///
/// A prayer reminder that only works when the user remembers to open it is not a
/// prayer reminder, so this is offered prominently at first run.
enum LaunchAtLogin {
    private static let log = Logger(subsystem: Barakah.subsystem, category: "login")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the user has explicitly disallowed the login item in System
    /// Settings, which the app cannot override and should explain rather than
    /// silently fail at.
    static var isBlockedByUser: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            log.error("launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
            return false
        }
    }
}
