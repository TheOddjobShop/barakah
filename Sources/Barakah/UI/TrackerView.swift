import AppKit
import SwiftUI

/// The prayer tracker — tracker_ui.py on Linux. A year of prayer as GitHub
/// draws a year of contributions: one square a day, as green as it was kept.
/// Above it the streaks and how much was prayed on time; below it the day
/// picked on the heatmap (today, to begin with), whose five prayers can each be
/// corrected — prayed at the masjid with the laptop shut, made up later, not
/// owed, or cleared — because the oath was the user's word in the first place.
struct TrackerView: View {
    @Bindable var app: AppState
    /// The day picked on the heatmap; today while nil or no longer shown.
    @State private var selected: String?

    var body: some View {
        // Statuses move with the clock: a window opens, another is missed.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let records = app.history(days: HeatmapLayout.days)
            let picked = records.first(where: { $0.day == selected }) ?? records.first
            VStack(alignment: .leading, spacing: 0) {
                summary(records)
                yearCard(records, picked: picked?.day)
                if let picked {
                    dayDetail(picked, isToday: picked.day == records.first?.day)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: 900, height: 560)
    }

    // MARK: - Summary

    private func summary(_ records: [DayRecord]) -> some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 0) {
                Text(String(PrayerTracker.streak(records)))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("day streak")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            figure(String(PrayerTracker.longestStreak(records)), caption: "longest streak, in days")
            figure(percent(PrayerTracker.onTimeRatio(Array(records.prefix(7)))), caption: "on time · this week")
            figure(percent(PrayerTracker.onTimeRatio(Array(records.prefix(30)))), caption: "on time · last 30 days")
            figure(percent(PrayerTracker.onTimeRatio(records)), caption: "on time · this year")
        }
        .padding(20)
    }

    private func figure(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func percent(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        return String(Int((ratio * 100).rounded())) + "%"
    }

    // MARK: - The year

    private func yearCard(_ records: [DayRecord], picked: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PrayerTracker.yearFooter(records))
                .font(.system(size: 15, weight: .semibold))
            HeatmapView(records: records, cell: 12, gap: 3, selected: picked, onSelect: { day in
                selected = day
            })
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - The day picked

    private func dayDetail(_ record: DayRecord, isToday: Bool) -> some View {
        let times = athanTimes(for: record.day)
        let title: String = isToday ? "Today" : HeatmapLayout.longDate(record.day)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(PrayerTracker.describe(record, today: isToday))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .center, horizontalSpacing: 48, verticalSpacing: 6) {
                GridRow {
                    ForEach(PrayerKind.prayers) { kind in
                        Text(kind.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    ForEach(PrayerKind.prayers) { kind in
                        Text(times[kind] ?? "")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    ForEach(PrayerKind.prayers) { kind in
                        cell(day: record.day, kind: kind, status: record.statuses[kind] ?? .untracked)
                    }
                }
                GridRow {
                    ForEach(PrayerKind.prayers) { kind in
                        Text((record.statuses[kind] ?? .untracked).label)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
    }

    /// Each prayer's athan on that place-day, in the place's time zone.
    private func athanTimes(for key: String) -> [PrayerKind: String] {
        let settings = app.settings
        let zone = settings.activePlace.timeZone
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return [:] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let noon = calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return [:] }
        let formatter = PrayerFormatter(use24Hour: settings.use24HourClock, timeZone: zone)
        var out: [PrayerKind: String] = [:]
        for window in PrayerTracker.windows(for: noon, settings: settings) {
            out[window.kind] = formatter.time(window.start)
        }
        return out
    }

    @ViewBuilder
    private func cell(day: String, kind: PrayerKind, status: PrayerStatus) -> some View {
        if status == .upcoming {
            StatusDot(status: status, accent: Theme.accent(for: kind), size: 22)
                .help("\(kind.name) · \(status.label)")
        } else {
            Button {
                showMenu(day: day, kind: kind, status: status)
            } label: {
                StatusDot(status: status, accent: Theme.accent(for: kind), size: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(kind.name) · \(status.label)")
        }
    }

    // MARK: - Correcting the record

    /// A real menu at the pointer. SwiftUI's `Menu` on macOS draws only text
    /// and images in its label, so it cannot be the dot itself.
    private func showMenu(day: String, kind: PrayerKind, status: PrayerStatus) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "\(kind.name) · \(status.label)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        // "Prayed on time" for any window that has begun, past ones included:
        // the prayer may have been at the masjid with the laptop shut, and the
        // record is the user's word either way.
        menu.addItem(item("Prayed on time", enabled: status != .prayed) { [app] in
            app.setStatus(day: day, prayer: kind, status: .prayed)
        })
        menu.addItem(item("Made up (qada)", enabled: status != .qada) { [app] in
            app.setStatus(day: day, prayer: kind, status: .qada)
        })
        menu.addItem(item("Excused — not owed", enabled: status != .excused) { [app] in
            app.setStatus(day: day, prayer: kind, status: .excused)
        })
        if status.isRecordable {
            menu.addItem(.separator())
            menu.addItem(item("Clear", enabled: true) { [app] in
                app.setStatus(day: day, prayer: kind, status: nil)
            })
        }

        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func item(_ title: String, enabled: Bool, action: @escaping () -> Void) -> NSMenuItem {
        let handler = MenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        item.target = handler
        // The item's target is weak; this is what keeps the handler alive.
        item.representedObject = handler
        item.isEnabled = enabled
        return item
    }
}

/// Runs a closure from an AppKit menu item.
@MainActor
private final class MenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
        super.init()
    }

    @objc func run() {
        action()
    }
}

/// One prayer on one day: filled when recorded or missed, a ring while its
/// time is now, faint before then. Colours match the Linux tracker.
struct StatusDot: View {
    let status: PrayerStatus
    let accent: Color
    var size: CGFloat = 20

    static func colour(for status: PrayerStatus) -> Color? {
        switch status {
        case .prayed: return Color(red: 0.25, green: 0.70, blue: 0.50)
        case .qada: return Color(red: 0.88, green: 0.64, blue: 0.23)
        case .excused: return Color(red: 0.49, green: 0.56, blue: 0.70)
        case .missed: return Color(red: 0.88, green: 0.36, blue: 0.36)
        case .open, .upcoming, .untracked: return nil
        }
    }

    var body: some View {
        ZStack {
            if let fill = StatusDot.colour(for: status) {
                Circle()
                    .fill(fill)
                    .frame(width: size - 4, height: size - 4)
                if status == .prayed || status == .qada {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(Color.white)
                }
            } else if status == .open {
                Circle()
                    .strokeBorder(accent, lineWidth: 2.5)
                    .frame(width: size - 4, height: size - 4)
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.22))
                    .frame(width: size * 0.5, height: size * 0.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(status.label)
    }
}
