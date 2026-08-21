import SwiftUI
import UniformTypeIdentifiers

// MARK: - Iqama

/// Iqama cannot be calculated — it is whatever the masjid decided — so this tab
/// is about capturing that decision accurately, per prayer, with a Friday
/// override for Jumu'ah.
struct IqamaSettingsView: View {
    @Bindable var app: AppState

    var body: some View {
        Form {
            Section {
                Text("Iqama is set by your masjid, so Barakah cannot work it out. Give it either an offset after the athan or a fixed time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(PrayerKind.prayers) { kind in
                Section(kind.name) {
                    IqamaRuleEditor(
                        rule: Binding(
                            get: { app.settings.config(for: kind).iqamaRule },
                            set: { rule in app.updateConfig(for: kind) { $0.iqamaRule = rule } }
                        ),
                        use24Hour: app.settings.use24HourClock
                    )

                    if app.settings.config(for: kind).iqamaRule.isEnabled {
                        Stepper(
                            value: Binding(
                                get: { app.settings.config(for: kind).iqamaReminderMinutes },
                                set: { value in app.updateConfig(for: kind) { $0.iqamaReminderMinutes = value } }
                            ),
                            in: 0...60
                        ) {
                            let minutes = app.settings.config(for: kind).iqamaReminderMinutes
                            LabeledContent("Remind me before iqama") {
                                Text(minutes == 0 ? "Off" : "\(minutes) min before")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Toggle("Also notify at iqama itself", isOn: Binding(
                            get: { app.settings.config(for: kind).iqamaAlertEnabled },
                            set: { value in app.updateConfig(for: kind) { $0.iqamaAlertEnabled = value } }
                        ))
                    }
                }
            }

            Section("Jumu'ah") {
                Toggle("Use a separate time on Fridays", isOn: Binding(
                    get: { app.settings.jumuahEnabled },
                    set: { value in app.updateSettings { $0.jumuahEnabled = value } }
                ))
                if app.settings.jumuahEnabled {
                    IqamaRuleEditor(
                        rule: Binding(
                            get: { app.settings.jumuahIqamaRule },
                            set: { rule in app.updateSettings { $0.jumuahIqamaRule = rule } }
                        ),
                        use24Hour: app.settings.use24HourClock
                    )
                    Stepper(
                        value: Binding(
                            get: { app.settings.jumuahReminderMinutes },
                            set: { value in app.updateSettings { $0.jumuahReminderMinutes = value } }
                        ),
                        in: 0...90
                    ) {
                        LabeledContent("Remind me before khutbah") {
                            Text("\(app.settings.jumuahReminderMinutes) min before")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Replaces Dhuhr's iqama on Fridays only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Editor for a single iqama rule: off, an offset, or a fixed clock time.
struct IqamaRuleEditor: View {
    @Binding var rule: IqamaRule
    var use24Hour: Bool

    private enum Mode: String, CaseIterable, Identifiable {
        case off, offset, fixed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: "Off"
            case .offset: "After athan"
            case .fixed: "Fixed time"
            }
        }
    }

    private var mode: Mode {
        switch rule {
        case .none: .off
        case .offset: .offset
        case .fixed: .fixed
        }
    }

    var body: some View {
        Picker("Iqama", selection: Binding(
            get: { mode },
            set: { newMode in
                switch newMode {
                case .off: rule = .none
                case .offset: if case .offset = rule {} else { rule = .offset(minutes: 10) }
                case .fixed: if case .fixed = rule {} else { rule = .fixed(hour: 13, minute: 30) }
                }
            }
        )) {
            ForEach(Mode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)

        switch rule {
        case .none:
            EmptyView()

        case .offset(let minutes):
            Stepper(value: Binding(
                get: { minutes },
                set: { rule = .offset(minutes: $0) }
            ), in: 1...120) {
                LabeledContent("Minutes after athan") {
                    Text("\(minutes) min").monospacedDigit().foregroundStyle(.secondary)
                }
            }

        case .fixed(let hour, let minute):
            DatePicker(
                "Time",
                selection: Binding(
                    get: {
                        Calendar.current.date(from: DateComponents(
                            year: 2000, month: 1, day: 1, hour: hour, minute: minute)) ?? Date()
                    },
                    set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        rule = .fixed(hour: parts.hour ?? 13, minute: parts.minute ?? 30)
                    }
                ),
                displayedComponents: .hourAndMinute
            )
        }
    }
}

// MARK: - Athan

struct AthanSettingsView: View {
    @Bindable var app: AppState
    @State private var isPickingFile = false
    @State private var pickingForFajr = false

    var body: some View {
        Form {
            if AthanLibrary.available().isEmpty {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("No adhan recording installed")
                                .font(.system(size: 12, weight: .medium))
                            Text("Barakah ships none, because every recording of the adhan is copyrighted even though the words are not. Add one you have and Barakah will match its volume to everything else.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Button("Choose a file…") { pickingForFajr = false; isPickingFile = true }
                                Button("Open the Athan folder") {
                                    NSWorkspace.shared.open(AthanLibrary.installedDirectory)
                                }
                            }
                            .controlSize(.small)
                            .padding(.top, 2)
                        }
                    } icon: {
                        Image(systemName: "waveform.badge.plus").foregroundStyle(.orange)
                    }
                }
            }

            Section("Sound") {
                AthanSoundPicker(
                    title: "Athan",
                    sound: Binding(
                        get: { app.settings.athanSound },
                        set: { value in app.updateSettings { $0.athanSound = value } }
                    ),
                    onChooseFile: { pickingForFajr = false; isPickingFile = true }
                )

                Toggle("Use a different sound for Fajr", isOn: Binding(
                    get: { app.settings.fajrAthanSound != nil },
                    set: { enabled in
                        app.updateSettings { $0.fajrAthanSound = enabled ? .chime : nil }
                    }
                ))
                if app.settings.fajrAthanSound != nil {
                    AthanSoundPicker(
                        title: "Fajr athan",
                        sound: Binding(
                            get: { app.settings.fajrAthanSound ?? .chime },
                            set: { value in app.updateSettings { $0.fajrAthanSound = value } }
                        ),
                        onChooseFile: { pickingForFajr = true; isPickingFile = true }
                    )
                    Text("The Fajr athan includes the extra line “prayer is better than sleep”, so it is usually a separate recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(app.audio.isPlaying ? "Stop" : "Preview") {
                        if app.audio.isPlaying {
                            app.audio.stop(notify: false)
                        } else {
                            app.audio.preview(app.settings.athanSound, volume: app.settings.athanVolume)
                        }
                    }
                    Spacer()
                }
            }

            Section("Volume") {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { app.settings.athanVolume },
                        set: { value in app.updateSettings { $0.athanVolume = value } }
                    ), in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }

                Stepper(value: Binding(
                    get: { app.settings.athanMaxSeconds },
                    set: { value in app.updateSettings { $0.athanMaxSeconds = value } }
                ), in: 0...600, step: 15) {
                    LabeledContent("Stop automatically after") {
                        Text(app.settings.athanMaxSeconds == 0
                             ? "Play in full"
                             : "\(app.settings.athanMaxSeconds)s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Barakah plays the athan itself rather than as a notification sound, so it can run its full length and be stopped with one click on the menu bar icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Which prayers") {
                ForEach(PrayerKind.prayers) { kind in
                    Toggle(kind.name, isOn: Binding(
                        get: { app.settings.config(for: kind).athanEnabled },
                        set: { value in app.updateConfig(for: kind) { $0.athanEnabled = value } }
                    ))
                }
            }

            Section {
                Toggle("Show a floating window while the athan plays", isOn: Binding(
                    get: { app.settings.showAthanWindow },
                    set: { value in app.updateSettings { $0.showAthanWindow = value } }
                ))
                if let error = app.audio.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        ) { result in
            guard case .success(let url) = result,
                  let sound = try? AudioService.bookmark(for: url) else { return }
            let forFajr = pickingForFajr
            app.updateSettings { settings in
                if forFajr { settings.fajrAthanSound = sound } else { settings.athanSound = sound }
            }
        }
    }
}

/// Picker over the available athan sounds, including any bundled with the app
/// and whatever file the user has chosen.
struct AthanSoundPicker: View {
    var title: String
    @Binding var sound: AthanSound
    var onChooseFile: () -> Void

    /// Recordings installed by the user or bundled with the app, discovered at
    /// runtime so `make adhan` needs no code change to take effect.
    private var bundledNames: [String] { AthanLibrary.available() }

    var body: some View {
        Picker(title, selection: Binding(
            get: { Selection(sound: sound) },
            set: { selection in
                switch selection {
                case .chime: sound = .chime
                case .silent: sound = .silent
                case .bundled(let name): sound = .bundled(name)
                case .custom: onChooseFile()
                }
            }
        )) {
            Text("Chime (built in)").tag(Selection.chime)
            ForEach(bundledNames, id: \.self) { name in
                Text(AthanSound.bundledDisplayName(for: name)).tag(Selection.bundled(name))
            }
            if case .custom(_, let displayName) = sound {
                Text(displayName).tag(Selection.custom)
            }
            Divider()
            Text("Choose a file…").tag(Selection.custom)
            Text("Silent").tag(Selection.silent)
        }
    }

    private enum Selection: Hashable {
        case chime, silent, custom
        case bundled(String)

        init(sound: AthanSound) {
            switch sound {
            case .chime: self = .chime
            case .silent: self = .silent
            case .bundled(let name): self = .bundled(name)
            case .custom: self = .custom
            }
        }
    }
}
