import AppKit
import SwiftUI
import Combine

/// Owns the status item and the panel that hangs off it.
///
/// This is hand-rolled AppKit rather than SwiftUI's `MenuBarExtra` for one
/// specific reason: the athan has to be stoppable with a single click on the
/// icon. `MenuBarExtra` always consumes the click to open its own content, and
/// making someone open a panel and find a button to stop a sound that is playing
/// right now is the wrong interaction.
@MainActor
final class MenuBarController: NSObject {
    private let app: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var refreshTimer: Timer?
    private var athanWindow: AthanWindowController?
    private var playbackObserver: Any?

    var onOpenSettings: (() -> Void)?

    init(app: AppState) {
        self.app = app
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configurePopover()
        configureButton()
        startRefreshing()

        // The five-second tick is fine for a countdown, but far too slow for
        // the athan starting — the icon must become a stop button at once.
        playbackObserver = NotificationCenter.default.addObserver(
            forName: AudioService.playbackChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        refresh()
    }

    // MARK: - Setup

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                app: app,
                onOpenSettings: { [weak self] in
                    self?.closePanel()
                    self?.onOpenSettings?()
                },
                onQuit: { NSApp.terminate(nil) }
            )
        )
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(handleClick(_:))
        // Both mouse buttons route through the same action so a right-click can
        // show the quick menu without hijacking the left-click behaviour.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func startRefreshing() {
        // Five seconds keeps a minute-resolution countdown honest at the boundary
        // without waking the CPU more than necessary.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Appearance

    /// Re-render the menu bar label from current state.
    func refresh() {
        guard let button = statusItem.button else { return }

        let playing = app.audio.isPlaying
        let symbol = playing ? "speaker.wave.3.fill"
            : (app.isGloballyMuted ? "moon.stars" : "moon.stars.fill")

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Barakah")
        image?.isTemplate = true
        button.image = image

        button.title = playing ? " Stop athan" : " " + label()
        button.toolTip = playing
            ? "Click to stop the athan"
            : tooltip()

        // Presence of the athan window is driven from here so it tracks playback
        // regardless of which code path started or stopped it.
        syncAthanWindow(isPlaying: playing)
    }

    private func label() -> String {
        guard let next = app.nextPrayer else { return "—" }
        let formatter = PrayerFormatter(
            use24Hour: app.settings.use24HourClock,
            timeZone: app.settings.activePlace.timeZone
        )
        switch app.settings.menuBarStyle {
        case .countdown:
            return "\(next.kind.name) in \(formatter.countdown(next.athan.timeIntervalSinceNow))"
        case .nextTime:
            return "\(next.kind.name) \(formatter.time(next.athan))"
        case .nextName:
            return next.kind.name
        case .iconOnly:
            return ""
        }
    }

    private func tooltip() -> String {
        guard let next = app.nextPrayer else { return "Barakah" }
        let formatter = PrayerFormatter(
            use24Hour: app.settings.use24HourClock,
            timeZone: app.settings.activePlace.timeZone
        )
        var text = "\(next.kind.name) at \(formatter.time(next.athan))"
        if let iqama = next.iqama {
            text += "\nIqama at \(formatter.time(iqama))"
        }
        text += "\n\(app.settings.activePlace.name)"
        return text
    }

    // MARK: - Interaction

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent

        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
            return
        }

        // The whole reason this class exists: while the athan is sounding, the
        // icon is a stop button and nothing else.
        if app.audio.isPlaying {
            app.stopAthan()
            refresh()
            return
        }

        togglePanel()
    }

    private func togglePanel() {
        if popover.isShown {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without this the panel opens behind the frontmost app's windows.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePanel() {
        popover.performClose(nil)
    }

    private func showContextMenu() {
        let menu = NSMenu()

        if let next = app.nextPrayer {
            let formatter = PrayerFormatter(
                use24Hour: app.settings.use24HourClock,
                timeZone: app.settings.activePlace.timeZone
            )
            let item = NSMenuItem(
                title: "\(next.kind.name) at \(formatter.time(next.athan))",
                action: nil, keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Show times", action: #selector(menuShowPanel), keyEquivalent: "")
            .target = self

        if app.media.active != nil {
            menu.addItem(withTitle: "Resume paused media", action: #selector(menuResumeMedia), keyEquivalent: "")
                .target = self
        }

        let silence = NSMenuItem(
            title: app.isGloballyMuted ? "Turn athans back on" : "Silence athans for 1 hour",
            action: #selector(menuToggleSilence), keyEquivalent: ""
        )
        silence.target = self
        menu.addItem(silence)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Quit Barakah", action: #selector(menuQuit), keyEquivalent: "q")
            .target = self

        // Attaching the menu and immediately clearing it keeps the left-click
        // action intact; a permanently attached menu would swallow it.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuShowPanel() { openPanel() }
    @objc private func menuResumeMedia() { app.resumeMediaNow() }
    @objc private func menuToggleSilence() {
        app.mute(for: app.isGloballyMuted ? nil : 3600)
        refresh()
    }
    @objc private func menuSettings() { onOpenSettings?() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Athan window

    private func syncAthanWindow(isPlaying: Bool) {
        guard app.settings.showAthanWindow else {
            athanWindow?.close()
            athanWindow = nil
            return
        }
        if isPlaying {
            if athanWindow == nil {
                athanWindow = AthanWindowController(app: app)
            }
            athanWindow?.present(near: statusItem.button)
        } else {
            athanWindow?.close()
            athanWindow = nil
        }
    }

    func invalidate() {
        if let playbackObserver {
            NotificationCenter.default.removeObserver(playbackObserver)
            self.playbackObserver = nil
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        athanWindow?.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

private extension NSMenu {
    @discardableResult
    func addItem(withTitle title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        addItem(item)
        return item
    }
}
