import AppKit
import SwiftUI

/// The prayer lock: a cover over every screen that only "Wallahi, I prayed"
/// lifts — or the prayer's time ending.
///
/// Shown and hidden by MenuBarController from `AppState.lock`, which is
/// re-derived every two seconds, so quitting, sleeping or changing the clock
/// cannot skip it. While shown, the app holds the front: it re-activates when
/// another app is activated, rebuilds its windows when screens change, and
/// asks the system to hide the Dock and menu bar and to refuse app switching,
/// Force Quit, logout and hiding until it is lifted.
@MainActor
final class LockOverlayController {
    private let app: AppState
    private var prayer: PrayerWindow?
    /// A preview records nothing; its button only closes it.
    private var isPreview = false
    private var windows: [NSWindow] = []
    private var savedOptions: NSApplication.PresentationOptions?
    private var previousApp: NSRunningApplication?
    private var activationObserver: Any?
    private var screenObserver: Any?

    /// A valid combination: hiding the menu bar requires hiding the Dock, and
    /// disabling process switching requires the Dock hidden too.
    private static let lockedOptions: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
        .disableSessionTermination, .disableHideApplication,
    ]

    init(app: AppState) {
        self.app = app
    }

    var isShown: Bool { !windows.isEmpty }

    /// Cover the screens for `prayer`, or bring the cover back to the front if
    /// it is already up for it.
    func show(for prayer: PrayerWindow, preview: Bool = false) {
        if prayer == self.prayer, preview == isPreview, isShown {
            bringToFront()
            return
        }
        if !isShown {
            let front = NSWorkspace.shared.frontmostApplication
            let isUs = front?.processIdentifier == NSRunningApplication.current.processIdentifier
            previousApp = isUs ? nil : front
            observe()
        }
        self.prayer = prayer
        self.isPreview = preview
        buildWindows()
        bringToFront()
    }

    func hide() {
        stopObserving()
        prayer = nil
        isPreview = false
        retireWindows()
        if let savedOptions {
            NSApp.presentationOptions = savedOptions
            self.savedOptions = nil
        }
        if let previous = previousApp, !previous.isTerminated {
            _ = previous.activate(options: [])
        }
        previousApp = nil
    }

    // MARK: - Windows

    private func buildWindows() {
        retireWindows()
        guard let prayer else { return }
        for (index, screen) in NSScreen.screens.enumerated() {
            let window = LockWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.backgroundColor = LockPalette.backdropNS
            window.hasShadow = false
            window.isMovable = false
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none

            // The first screen is the one with the menu bar; it carries the
            // oath. The others only need to be covered.
            let content: NSView
            if index == 0 {
                let hosting = NSHostingView(rootView: LockView(app: app, window: prayer, isPreview: isPreview))
                hosting.sizingOptions = []
                content = hosting
            } else {
                let hosting = NSHostingView(rootView: LockBackdropView(window: prayer))
                hosting.sizingOptions = []
                content = hosting
            }
            window.contentView = content
            window.setFrame(screen.frame, display: true)
            windows.append(window)
        }
    }

    /// Take the windows off screen now, and close them once the current event
    /// has finished — the oath button's own action is what hides them.
    private func retireWindows() {
        let retiring = windows
        windows = []
        for window in retiring { window.orderOut(nil) }
        Task { @MainActor in
            for window in retiring { window.close() }
        }
    }

    private func bringToFront() {
        if savedOptions == nil {
            savedOptions = NSApp.presentationOptions
        }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if NSApp.presentationOptions != Self.lockedOptions {
            NSApp.presentationOptions = Self.lockedOptions
        }
        for window in windows.dropFirst() {
            window.orderFrontRegardless()
        }
        windows.first?.makeKeyAndOrderFront(nil)
        windows.first?.orderFrontRegardless()
    }

    // MARK: - Holding the front

    private func observe() {
        stopObserving()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isUs = activated?.processIdentifier == NSRunningApplication.current.processIdentifier
            MainActor.assumeIsolated {
                if !isUs { self?.reclaimFront() }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// Another app came forward — from a notification, Spotlight, a Dock
    /// click — so take the front back.
    private func reclaimFront() {
        guard isShown else { return }
        bringToFront()
    }

    /// A display was added, removed or rearranged: cover the new set.
    private func screensChanged() {
        guard prayer != nil else { return }
        buildWindows()
        bringToFront()
    }

    private func stopObserving() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }
}

/// A borderless window that can still take the keyboard, so keys go to the
/// cover rather than to whatever is underneath.
private final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Borderless windows are not normally kept below the menu bar, but say so
    /// explicitly: the cover must take the whole screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private enum LockPalette {
    static let backdrop = Color(red: 0.05, green: 0.05, blue: 0.07)
    static var backdropNS: NSColor { NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.07, alpha: 1) }

    /// The prayer's time marker that ends its window.
    static func endName(for kind: PrayerKind) -> String {
        switch kind {
        case .fajr: return PrayerKind.sunrise.name
        case .dhuhr: return PrayerKind.asr.name
        case .asr: return PrayerKind.maghrib.name
        case .maghrib: return PrayerKind.isha.name
        case .isha: return PrayerKind.fajr.name
        case .sunrise: return PrayerKind.dhuhr.name
        }
    }
}

/// The dark wash behind everything, tinted with the prayer's accent.
private struct LockBackground: View {
    var accent: Color

    var body: some View {
        ZStack {
            LockPalette.backdrop
            RadialGradient(
                colors: [accent.opacity(0.30), Color.clear],
                center: .top,
                startRadius: 0,
                endRadius: 900
            )
        }
        .ignoresSafeArea()
    }
}

/// What every screen but the main one shows.
private struct LockBackdropView: View {
    let window: PrayerWindow

    var body: some View {
        ZStack {
            LockBackground(accent: Theme.accent(for: window.kind))
            VStack(spacing: 8) {
                Text(window.kind.arabicName)
                    .font(.system(size: 64))
                Text(window.kind.name)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            .foregroundStyle(Color.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

/// The cover on the main screen: the prayer, its time, the verse, and the oath.
private struct LockView: View {
    @Bindable var app: AppState
    let window: PrayerWindow
    let isPreview: Bool

    private var accent: Color { Theme.accent(for: window.kind) }

    private var formatter: PrayerFormatter {
        PrayerFormatter(
            use24Hour: app.settings.use24HourClock,
            // The place's zone, like every other time Barakah shows.
            timeZone: app.settings.activePlace.timeZone
        )
    }

    private var beganLine: String {
        var text = "\(window.kind.name) began at \(formatter.time(window.start))"
        if let iqama = window.iqama {
            text += " · iqama \(formatter.time(iqama))"
        }
        return text
    }

    private var untilLine: String {
        "until \(LockPalette.endName(for: window.kind)) at \(formatter.time(window.end))"
    }

    private var oath: String {
        "Wallahi, I prayed \(window.kind.name)"
    }

    var body: some View {
        ZStack {
            LockBackground(accent: accent)

            VStack(spacing: 34) {
                VStack(spacing: 4) {
                    Text(window.kind.arabicName)
                        .font(.system(size: 104))
                    Text(window.kind.name)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color.white)

                VStack(spacing: 6) {
                    Text(beganLine)
                    Text(untilLine)
                }
                .font(.system(size: 17))
                .foregroundStyle(Color.white.opacity(0.72))

                VStack(spacing: 10) {
                    Text("إِنَّ الصَّلَاةَ كَانَتْ عَلَى الْمُؤْمِنِينَ كِتَابًا مَّوْقُوتًا")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.white.opacity(0.9))
                    Text("Indeed, prayer has been decreed upon the believers at fixed times. — An-Nisa 4:103")
                        .font(.system(size: 14))
                        .italic()
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 720)

                Button {
                    if isPreview {
                        app.endLockPreview()
                    } else {
                        app.confirmPrayed(window)
                    }
                } label: {
                    Text(oath)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 40)
                        .padding(.vertical, 18)
                        .background(accent, in: Capsule())
                        .foregroundStyle(Color.white)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .shadow(color: accent.opacity(0.45), radius: 18)
                .accessibilityLabel(oath)

                if app.audio.isPlaying {
                    Button("Stop athan", systemImage: "stop.fill") { app.stopAthan() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(Color.white.opacity(0.65))
                }

                if isPreview {
                    Text("Preview — nothing is recorded, and this closes by itself.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
            .padding(48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}
