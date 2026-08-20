import SwiftUI

/// The panel that drops from the menu bar: the whole day at a glance, with the
/// next prayer given the most weight.
struct PopoverView: View {
    @Bindable var app: AppState
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    private var formatter: PrayerFormatter {
        PrayerFormatter(
            use24Hour: app.settings.use24HourClock,
            // Displayed in the *place's* timezone, matching the times themselves,
            // so a pinned hometown reads correctly from anywhere in the world.
            timeZone: app.settings.activePlace.timeZone
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            prayerList
            Divider().opacity(0.5)
            footer
        }
        .frame(width: Theme.panelWidth)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var header: some View {
        // Re-renders once a second, but only while the panel is actually on
        // screen — a closed popover costs nothing.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Group {
                if app.audio.isPlaying {
                    athanPlayingHeader
                } else {
                    nextPrayerHeader
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.headerGradient(for: headerAccentKind))
        }
    }

    private var headerAccentKind: PrayerKind? {
        app.audio.playingPrayer ?? app.nextPrayer?.kind ?? app.currentPrayer?.kind
    }

    private var nextPrayerHeader: some View {
        HStack(spacing: 14) {
            CountdownRing(
                progress: app.windowProgress,
                accent: Theme.accent(for: headerAccentKind),
                symbolName: app.nextPrayer?.kind.symbolName ?? "moon.stars"
            )

            VStack(alignment: .leading, spacing: 2) {
                if let next = app.nextPrayer {
                    HStack(spacing: 6) {
                        Text(next.kind.name)
                            .font(Theme.headlineFont)
                        Text(next.kind.arabicName)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }

                    Text(formatter.longCountdown(next.athan.timeIntervalSinceNow))
                        .font(Theme.countdownFont)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 5) {
                        Text(formatter.time(next.athan))
                        if let iqama = next.iqama {
                            Text("·").foregroundStyle(.tertiary)
                            Text("iqama \(formatter.time(iqama))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                } else {
                    Text("No times available")
                        .font(Theme.headlineFont)
                    Text("Set a location in Settings")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var athanPlayingHeader: some View {
        HStack(spacing: 14) {
            CountdownRing(
                progress: app.audio.progress,
                accent: Theme.accent(for: app.audio.playingPrayer),
                symbolName: "speaker.wave.3.fill"
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(app.audio.playingPrayer.map { "\($0.name) — athan" } ?? "Athan")
                    .font(Theme.headlineFont)

                if let summary = app.interruptionSummary {
                    Label(summary, systemImage: "pause.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Button("Stop", systemImage: "stop.fill") { app.stopAthan() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    if app.media.active != nil {
                        Button("Resume media", systemImage: "play.fill") { app.resumeMediaNow() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - List

    /// Column labels. Without them, two times on a row are ambiguous — and the
    /// difference between athan and iqama is the whole reason to show both.
    private var columnHeader: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text("Athan")
                .frame(width: Theme.timeColumnWidth, alignment: .trailing)
            Text("Iqama")
                .frame(width: Theme.timeColumnWidth, alignment: .trailing)
            Color.clear.frame(width: 14)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 3)
    }

    private var prayerList: some View {
        VStack(spacing: 1) {
            if let today = app.scheduler.today {
                columnHeader
                ForEach(today.prayers) { prayer in
                    PrayerRowView(
                        prayer: prayer,
                        formatter: formatter,
                        state: state(for: prayer, in: today),
                        isMuted: app.mutedToday.contains(prayer.kind),
                        onToggleMute: { app.toggleMuteToday(prayer.kind) }
                    )
                }
            } else {
                ContentUnavailableView(
                    "No prayer times",
                    systemImage: "location.slash",
                    description: Text("Barakah needs a location to calculate times.")
                )
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private func state(for prayer: ScheduledPrayer, in day: DaySchedule) -> PrayerRowView.RowState {
        let now = Date()
        if prayer.kind == app.nextPrayer?.kind, prayer.athan > now { return .next }
        if prayer.athan <= now {
            return day.currentPrayer(at: now)?.kind == prayer.kind ? .current : .past
        }
        return .upcoming
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(app.settings.activePlace.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if app.settings.showHijriDate {
                    Text(formatter.hijriDate(Date()))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if app.isGloballyMuted, let until = app.mutedUntil {
                HStack(spacing: 5) {
                    Image(systemName: "bell.slash.fill")
                    Text("All athans silenced until \(formatter.time(until))")
                    Spacer()
                    Button("Undo") { app.mute(for: nil) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }

            HStack(spacing: 4) {
                Menu {
                    Button("15 minutes") { app.mute(for: 15 * 60) }
                    Button("1 hour") { app.mute(for: 3600) }
                    Button("Until tomorrow") { app.mute(for: secondsUntilTomorrow()) }
                    if app.isGloballyMuted {
                        Divider()
                        Button("Turn athans back on") { app.mute(for: nil) }
                    }
                } label: {
                    Label("Silence", systemImage: app.isGloballyMuted ? "bell.slash.fill" : "bell.slash")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button("Settings…", systemImage: "gearshape") { onOpenSettings() }
                    .labelStyle(.iconOnly)
                    .help("Settings")

                Button("Quit", systemImage: "power") { onQuit() }
                    .labelStyle(.iconOnly)
                    .help("Quit Barakah")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func secondsUntilTomorrow() -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = app.settings.activePlace.timeZone
        let start = calendar.startOfDay(for: Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) else { return 8 * 3600 }
        return tomorrow.timeIntervalSinceNow
    }
}
