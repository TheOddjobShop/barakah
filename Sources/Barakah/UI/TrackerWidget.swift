import AppKit
import SwiftUI

/// The prayer heatmap as a desktop widget — desktop_widget.py on Linux.
///
/// A WidgetKit widget needs an app extension built by Xcode, which this SwiftPM
/// build cannot ship, so this is what Übersicht-style widgets are: a borderless
/// window just above the desktop icons — below every app window, on every
/// Space, out of the app switcher. It draws its own GitHub-dark card. Drag it
/// anywhere; where it was left is kept under its frame autosave name in this
/// Mac's defaults, not in settings, because screen coordinates mean nothing on
/// another machine. Right-click for the tracker, or to take it off the desktop.
///
/// Shown and hidden by MenuBarController, from `settings.widget.enabled` alone.
@MainActor
final class TrackerWidgetController {
    static let autosaveName = "BarakahTrackerWidget"
    /// Its first place: the bottom right of the main screen, this far in.
    private static let inset: CGFloat = 32

    private let app: AppState
    private let openTracker: () -> Void
    private var panel: NSPanel?

    init(app: AppState, openTracker: @escaping () -> Void) {
        self.app = app
        self.openTracker = openTracker
    }

    func show() {
        if panel == nil { build() }
        panel?.orderFrontRegardless()
    }

    /// Off the screen now, closed once the current event is done: "Remove from
    /// desktop" runs inside the widget's own context menu.
    func close() {
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        Task { @MainActor in
            panel.close()
        }
    }

    private func build() {
        let view = TrackerWidgetView(
            app: app,
            onOpenTracker: { [weak self] in self?.openTracker() },
            onRemove: { [weak self] in self?.app.updateWidget { $0.enabled = false } }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]

        // Non-activating, like the athan panel: clicking the widget must not
        // pull Barakah to the front.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        // Above the desktop icons, below every ordinary window.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let size = hosting.view.fittingSize
        if size.width > 0, size.height > 0 {
            panel.setContentSize(size)
        }
        place(panel)
        _ = panel.setFrameAutosaveName(Self.autosaveName)
        self.panel = panel
    }

    /// Where it was left, if that is still on a screen; otherwise the bottom
    /// right of the main screen, clear of the Dock and the edge.
    private func place(_ panel: NSPanel) {
        if panel.setFrameUsingName(Self.autosaveName) {
            let frame = panel.frame
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                return
            }
            // Left on a screen that is gone.
            NSWindow.removeFrame(usingName: Self.autosaveName)
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: area.maxX - size.width - Self.inset,
            y: area.minY + Self.inset))
    }
}

/// The widget's card: the year's count and the streak over the heatmap, with
/// today in its footer.
struct TrackerWidgetView: View {
    @Bindable var app: AppState
    let onOpenTracker: () -> Void
    let onRemove: () -> Void

    var body: some View {
        // Today's square moves with the clock; anything recorded redraws it at
        // once, since reading the app here observes it.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            card(app.history(days: HeatmapLayout.days))
        }
        .fixedSize()
        .contextMenu {
            Button("Open prayer tracker") { onOpenTracker() }
            Button("Remove from desktop") { onRemove() }
        }
    }

    private func card(_ records: [DayRecord]) -> some View {
        let days = PrayerTracker.streak(records)
        let streak: String = days > 0 ? "\(days)-day streak" : "No streak yet"
        let today: String = records.first.map { "Today: " + PrayerTracker.describe($0, today: true) } ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(PrayerTracker.yearFooter(records))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xE6EDF3))
                Spacer(minLength: 12)
                Text(streak)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x39D353))
            }
            HeatmapView(records: records, cell: 10, gap: 3, palette: .dark, footer: today)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: 0x0D1117, opacity: 0.96))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(hex: 0x30363D), lineWidth: 1)
        }
    }
}
