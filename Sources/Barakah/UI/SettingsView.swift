import SwiftUI
import Adhan

/// The settings window: six tabs, each answering one question the user actually
/// has. Grouped by *what they want to change* rather than by which subsystem
/// implements it.
struct SettingsView: View {
    @Bindable var app: AppState

    var body: some View {
        TabView {
            LocationSettingsView(app: app)
                .tabItem { Label("Location", systemImage: "location") }
            CalculationSettingsView(app: app)
                .tabItem { Label("Calculation", systemImage: "function") }
            IqamaSettingsView(app: app)
                .tabItem { Label("Iqama", systemImage: "person.3") }
            AthanSettingsView(app: app)
                .tabItem { Label("Athan", systemImage: "speaker.wave.2") }
            MediaSettingsView(app: app)
                .tabItem { Label("Media", systemImage: "pause.rectangle") }
            GeneralSettingsView(app: app)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - Location

struct LocationSettingsView: View {
    @Bindable var app: AppState
    @State private var query = ""
    @State private var results: [PlaceSetting] = []
    @State private var isSearching = false

    var body: some View {
        Form {
            Section {
                Picker("Location", selection: Binding(
                    get: { app.settings.locationMode },
                    set: { mode in app.updateSettings { $0.locationMode = mode } }
                )) {
                    ForEach(LocationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            if app.settings.locationMode == .automatic {
                Section {
                    if app.location.isDenied {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Location access is turned off.")
                                Text("Barakah cannot calculate times without it. Either allow access or set a location manually.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Open Privacy Settings") {
                                    NSWorkspace.shared.open(URL(string:
                                        "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                                }
                                .controlSize(.small)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    } else if app.location.needsPermission {
                        Button("Allow location access") { app.location.requestPermission() }
                    } else {
                        LabeledContent("Detected") {
                            HStack(spacing: 6) {
                                Text(app.settings.resolvedPlace?.name ?? "Locating…")
                                if app.location.isResolving { ProgressView().controlSize(.small) }
                            }
                        }
                        Button("Update now") { app.location.refresh() }
                            .controlSize(.small)
                    }
                }
            } else {
                Section("Search for a city") {
                    HStack {
                        TextField("City", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { runSearch() }
                        Button("Search") { runSearch() }
                            .disabled(query.trimmingCharacters(in: .whitespaces).count < 2)
                    }
                    if isSearching { ProgressView().controlSize(.small) }
                    ForEach(results, id: \.self) { place in
                        Button {
                            app.updateSettings { $0.manualPlace = place }
                            results = []
                            query = ""
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(place.name)
                                Text("\(place.shortCoordinateDescription) · \(place.timeZoneIdentifier)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("In use") {
                let place = app.settings.activePlace
                LabeledContent("Place", value: place.name)
                LabeledContent("Coordinates", value: place.shortCoordinateDescription)
                LabeledContent("Time zone", value: place.timeZoneIdentifier)
            }
        }
        .formStyle(.grouped)
    }

    private func runSearch() {
        isSearching = true
        Task {
            results = await app.location.search(query)
            isSearching = false
        }
    }
}

// MARK: - Calculation

struct CalculationSettingsView: View {
    @Bindable var app: AppState

    var body: some View {
        Form {
            Section {
                Picker("Method", selection: Binding(
                    get: { app.settings.calculationMethod },
                    set: { method in app.updateSettings { $0.calculationMethod = method } }
                )) {
                    ForEach(CalculationMethod.selectable, id: \.self) { method in
                        Text(method.label).tag(method)
                    }
                }
                Text("Methods differ in the sun's angle below the horizon used for Fajr and Isha. Use whichever your local masjid follows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Asr") {
                Picker("Madhab", selection: Binding(
                    get: { app.settings.madhab },
                    set: { madhab in app.updateSettings { $0.madhab = madhab } }
                )) {
                    ForEach(Madhab.allCases, id: \.self) { madhab in
                        Text(madhab.label).tag(madhab)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(app.settings.madhab.asrDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("High latitudes") {
                Picker("Rule", selection: Binding(
                    get: { app.settings.highLatitudeRule },
                    set: { rule in app.updateSettings { $0.highLatitudeRule = rule } }
                )) {
                    Text("Method default").tag(HighLatitudeRule?.none)
                    ForEach(HighLatitudeRule.allCases, id: \.self) { rule in
                        Text(rule.label).tag(HighLatitudeRule?.some(rule))
                    }
                }
                Text(app.settings.highLatitudeRule?.detail
                    ?? "Above roughly 48° the sun may never reach the required angle in summer, so Fajr and Isha need a convention.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fine adjustment") {
                Text("Minutes added to each calculated time, for matching a printed masjid timetable exactly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(PrayerKind.allCases) { kind in
                    Stepper(
                        value: Binding(
                            get: { app.settings.config(for: kind).athanAdjustmentMinutes },
                            set: { value in app.updateConfig(for: kind) { $0.athanAdjustmentMinutes = value } }
                        ),
                        in: -60...60
                    ) {
                        LabeledContent(kind.name) {
                            Text(signed(app.settings.config(for: kind).athanAdjustmentMinutes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func signed(_ minutes: Int) -> String {
        minutes == 0 ? "—" : (minutes > 0 ? "+\(minutes) min" : "\(minutes) min")
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Bindable var app: AppState
    @State private var launchAtLoginFailed = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch Barakah at login", isOn: Binding(
                    get: { app.settings.launchAtLogin },
                    set: { enabled in
                        let ok = LaunchAtLogin.set(enabled)
                        launchAtLoginFailed = !ok
                        app.updateSettings { $0.launchAtLogin = ok ? enabled : LaunchAtLogin.isEnabled }
                    }
                ))
                if launchAtLoginFailed || LaunchAtLogin.isBlockedByUser {
                    Label("macOS is blocking the login item. Enable Barakah under Login Items in System Settings.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Menu bar") {
                Picker("Show", selection: Binding(
                    get: { app.settings.menuBarStyle },
                    set: { style in app.updateSettings { $0.menuBarStyle = style } }
                )) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                Toggle("Use a 24-hour clock", isOn: binding(\.use24HourClock))
                Toggle("Show the Hijri date", isOn: binding(\.showHijriDate))
                Toggle("Show sunrise in the list", isOn: binding(\.showSunrise))
            }

            Section("Notifications") {
                if !app.notifications.isAuthorized {
                    HStack {
                        Label("Notifications are not enabled.", systemImage: "bell.slash")
                            .font(.caption)
                        Spacer()
                        Button("Enable") {
                            Task { await app.notifications.requestAuthorization() }
                        }
                        .controlSize(.small)
                    }
                }
                Toggle("Notify when a prayer time arrives", isOn: binding(\.notifyAtAthan))
                Toggle("Play the system notification sound too", isOn: binding(\.notificationSoundEnabled))
                Text("Iqama reminders are always delivered as notifications, and are scheduled ahead of time so they still arrive if Barakah is not running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Reset all settings") { app.settingsStore.resetToDefaults() }
                    Spacer()
                    Text("Barakah \(Bundle.main.appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ keyPath: WritableKeyPath<SettingsData, Bool>) -> Binding<Bool> {
        Binding(
            get: { app.settings[keyPath: keyPath] },
            set: { value in app.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
