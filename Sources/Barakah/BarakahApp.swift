import SwiftUI
import AppKit

/// Entry point.
///
/// Barakah has no main window, so it runs as an accessory app: no Dock tile, no
/// menu bar of its own, just the status item. `NSApplicationDelegateAdaptor`
/// drives it because the status item and the athan panel are both AppKit, and
/// wrapping them in a SwiftUI scene would cost the click behaviour that makes
/// the icon a stop button.
@main
struct BarakahApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A scene is required, but Barakah owns its windows directly, so this is
        // deliberately empty. Settings are presented from the delegate.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: AppState?
    private var menuBar: MenuBarController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let state = AppState()
        self.app = state

        let controller = MenuBarController(app: state)
        controller.onOpenSettings = { [weak self] in self?.showSettings() }
        self.menuBar = controller

        Task {
            await state.start()
            // Ask for notification permission only once there is something to
            // notify about, rather than with a cold dialog at first launch.
            if state.notifications.authorization == .notDetermined {
                await state.notifications.requestAuthorization()
                await state.notifications.reschedule(settings: state.settings, engine: PrayerTimeEngine())
            }
            controller.refresh()
        }

        // Keep the login-item toggle honest: the user can flip it in System
        // Settings behind our back.
        state.updateSettings { $0.launchAtLogin = LaunchAtLogin.isEnabled }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the user's media paused or their output muted because the
        // app went away mid-athan.
        app?.media.forget()
        app?.scheduler.invalidate()
        app?.flush()
        menuBar?.invalidate()
    }

    /// Clicking the Dock icon is impossible for an accessory app, but a second
    /// launch attempt should surface the panel rather than do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        menuBar?.refresh()
        return true
    }

    func showSettings() {
        guard let app else { return }

        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(app: app))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Barakah Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        // Settings changes are debounced; make sure the last one reaches disk.
        app?.flush()
        // Dropping back to accessory keeps Barakah out of the app switcher once
        // the only real window is gone.
        NSApp.setActivationPolicy(.accessory)
    }
}
