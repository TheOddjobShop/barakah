import AppKit
import SwiftUI

/// A small floating panel shown while the athan sounds.
///
/// The menu bar icon is already a stop button, but that only helps someone who
/// knows to look there. This panel puts the athan, what it interrupted, and the
/// way to stop it directly in view — then disappears the moment playback ends.
///
/// It is deliberately non-activating: it must never steal focus from whatever
/// the user is doing, and it must never appear in the Dock or the app switcher.
@MainActor
final class AthanWindowController {
    private let app: AppState
    private var panel: NSPanel?

    init(app: AppState) {
        self.app = app
    }

    func present(near button: NSStatusBarButton?) {
        if panel == nil { build() }
        guard let panel else { return }
        position(panel, near: button)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func build() {
        let hosting = NSHostingController(rootView: AthanWindowView(app: app) { [weak self] in
            self?.app.stopAthan()
            self?.close()
        })
        hosting.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        // Visible on every space and over full-screen apps — a prayer time does
        // not wait for you to switch desktops.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        self.panel = panel
    }

    /// Tuck the panel under the menu bar icon when we know where it is, and fall
    /// back to the top-right of the active screen when we do not.
    private func position(_ panel: NSPanel, near button: NSStatusBarButton?) {
        let size = panel.frame.size
        let margin: CGFloat = 12

        if let button,
           let buttonWindow = button.window,
           let screen = buttonWindow.screen ?? NSScreen.main {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            var x = buttonFrame.midX - size.width / 2
            // Keep it fully on screen when the icon sits near the right edge.
            x = min(x, screen.visibleFrame.maxX - size.width - margin)
            x = max(x, screen.visibleFrame.minX + margin)
            let y = buttonFrame.minY - size.height - 6
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - size.width - margin,
                y: screen.visibleFrame.maxY - size.height - margin
            ))
        }
    }
}

/// Contents of the floating athan panel.
private struct AthanWindowView: View {
    @Bindable var app: AppState
    var onStop: () -> Void

    private var accent: Color { Theme.accent(for: app.audio.playingPrayer) }

    var body: some View {
        HStack(spacing: 13) {
            CountdownRing(
                progress: app.audio.progress,
                accent: accent,
                symbolName: app.audio.playingPrayer?.symbolName ?? "speaker.wave.3.fill",
                size: 46
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.audio.playingPrayer?.name ?? "Athan")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(app.audio.playingPrayer?.arabicName ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                if let summary = app.interruptionSummary {
                    Label(summary, systemImage: "pause.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("It is time for prayer")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .background(accent.opacity(0.18), in: Circle())
            .foregroundStyle(accent)
            .help("Stop the athan")
        }
        .padding(14)
        .frame(width: 300)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.headerGradient(for: app.audio.playingPrayer))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(accent.opacity(0.25), lineWidth: 1)
                }
        }
    }
}
