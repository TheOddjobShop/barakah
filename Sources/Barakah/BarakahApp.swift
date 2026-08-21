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
    private var welcomeWindow: NSWindow?

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

        // Barakah ships no adhan recording, so without this a new user's first
        // prayer is announced by a synthesised bell and they reasonably assume
        // the app is broken. Ask once, up front.
        if !state.settings.hasCompletedOnboarding {
            showWelcome()
        }
    }

    func showWelcome() {
        guard let app else { return }
        if let window = welcomeWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Deliberately the same plain construction the settings window uses.
        // Combining a titled window with .fullSizeContentView, a hidden title and
        // preferredContentSize sizing produced an unsatisfiable constraint inside
        // NSHostingController and trapped in AppKit at first launch — which, for
        // a window that only ever appears on first launch, meant the app crashed
        // for new users and nobody else.
        let hosting = NSHostingController(rootView: WelcomeView(app: app) { [weak self] in
            self?.app?.updateSettings { $0.hasCompletedOnboarding = true }
            self?.welcomeWindow?.close()
        })

        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Barakah"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        welcomeWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        let closing = notification.object as? NSWindow

        if closing === welcomeWindow {
            // Closing the window counts as answering it. Asking again on every
            // launch would be nagging, and the chime is a working default.
            app?.updateSettings { $0.hasCompletedOnboarding = true }
            welcomeWindow = nil
            app?.flush()
            NSApp.setActivationPolicy(.accessory)
            return
        }

        guard closing === settingsWindow else { return }
        // Settings changes are debounced; make sure the last one reaches disk.
        app?.flush()
        // Dropping back to accessory keeps Barakah out of the app switcher once
        // the only real window is gone.
        NSApp.setActivationPolicy(.accessory)
    }
}
