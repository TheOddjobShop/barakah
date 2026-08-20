import SwiftUI

/// The tab that makes the media feature legible.
///
/// Pausing other apps is the part of Barakah most likely to half-work on any
/// given machine — a missing Automation grant, a player nothing can reach, an
/// OS release that tightens a private API. So this tab runs a live probe and
/// says plainly what will and will not happen, rather than letting the user find
/// out at Fajr.
struct MediaSettingsView: View {
    @Bindable var app: AppState
    @State private var diagnostics: MediaDiagnostics?
    @State private var isProbing = false

    var body: some View {
        Form {
            Section("When the athan starts") {
                ForEach(PrayerKind.prayers) { kind in
                    Picker(kind.name, selection: Binding(
                        get: { app.settings.config(for: kind).mediaMode },
                        set: { mode in app.updateConfig(for: kind) { $0.mediaMode = mode } }
                    )) {
                        ForEach(MediaPauseMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }
            }

            Section("Afterwards") {
                Picker("Resume what was paused", selection: Binding(
                    get: { ResumeChoice(mode: app.settings.resumeMode) },
                    set: { choice in app.updateSettings { $0.resumeMode = choice.mode } }
                )) {
                    ForEach(ResumeChoice.allCases) { choice in
                        Text(choice.mode.label).tag(choice)
                    }
                }
                Text("Only playback Barakah actually paused is resumed, and never when it could not tell whether something was playing — so resuming can't start audio you didn't ask for.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("How") {
                Toggle("Pause anything in Now Playing", isOn: Binding(
                    get: { app.settings.useMediaRemote },
                    set: { value in app.updateSettings { $0.useMediaRemote = value } }
                ))
                Text("Reaches browsers, IINA, and most players — the same channel as the play/pause key on your keyboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Control Spotify, Music, VLC and QuickTime directly", isOn: Binding(
                    get: { app.settings.useAppleScript },
                    set: { value in app.updateSettings { $0.useAppleScript = value } }
                ))
                Text("More precise, and the only way Barakah can tell what was playing so it can put it back. Needs Automation permission the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("What works on this Mac") {
                if let diagnostics {
                    DiagnosticRow(
                        ok: diagnostics.mediaRemoteLoaded,
                        title: "Now Playing control",
                        detail: diagnostics.mediaRemoteLoaded
                            ? "Available — Barakah can pause browsers and most players."
                            : "Unavailable on this macOS version. Direct app control still works."
                    )
                    DiagnosticRow(
                        ok: diagnostics.nowPlayingReadable,
                        warnOnly: true,
                        title: "Now Playing information",
                        detail: diagnostics.nowPlayingReadable
                            ? (diagnostics.nowPlayingDescription.map { "Reading: \($0)" } ?? "Readable.")
                            : "macOS hides this from apps without a private entitlement. Pausing still works; Barakah just can't name what it paused."
                    )
                    DiagnosticRow(
                        ok: !diagnostics.automationDenied,
                        title: "Automation permission",
                        detail: diagnostics.automationDenied
                            ? "Denied for at least one player. Grant it under Privacy & Security → Automation."
                            : "Granted, or not yet requested."
                    )
                    if diagnostics.automationDenied {
                        Button("Open Automation settings") {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }
                        .controlSize(.small)
                    }
                    LabeledContent("Playing right now") {
                        Text(diagnostics.detectedPlayers.isEmpty
                             ? "Nothing detected"
                             : diagnostics.detectedPlayers.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Run a check to see which methods are available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(isProbing ? "Checking…" : "Check now") { probe() }
                        .disabled(isProbing)
                    Button("Test pause") {
                        Task {
                            await app.media.interrupt(mode: .pause, settings: app.settings)
                            probe()
                        }
                    }
                    if app.media.active != nil {
                        Button("Resume") { app.resumeMediaNow() }
                    }
                    Spacer()
                    if isProbing { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
        .task { probe() }
    }

    private func probe() {
        isProbing = true
        Task {
            diagnostics = await app.media.diagnostics()
            isProbing = false
        }
    }

    /// `MediaResumeMode` carries an associated value, which a `Picker` cannot
    /// enumerate; this is the flat set actually offered.
    private enum ResumeChoice: String, CaseIterable, Identifiable, Hashable {
        case never, afterAthan, afterFive, afterIqama
        var id: String { rawValue }

        init(mode: MediaResumeMode) {
            switch mode {
            case .never: self = .never
            case .afterAthan: self = .afterAthan
            case .afterMinutes: self = .afterFive
            case .afterIqama: self = .afterIqama
            }
        }

        var mode: MediaResumeMode {
            switch self {
            case .never: .never
            case .afterAthan: .afterAthan
            case .afterFive: .afterMinutes(5)
            case .afterIqama: .afterIqama
            }
        }
    }
}

private struct DiagnosticRow: View {
    var ok: Bool
    var warnOnly: Bool = false
    var title: String
    var detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill"
                  : (warnOnly ? "info.circle.fill" : "xmark.circle.fill"))
                .foregroundStyle(ok ? .green : (warnOnly ? .secondary : .orange))
        }
    }
}
