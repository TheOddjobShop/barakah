import SwiftUI

/// Barakah's visual language.
///
/// The restraint is deliberate. Prayer apps drift towards gold filigree and
/// mosque silhouettes; this one aims to look like something Apple shipped, so it
/// sits in the menu bar without shouting. The single flourish is that the accent
/// follows the sun — the panel is indigo before Fajr and amber at Maghrib —
/// which carries real information rather than decoration.
enum Theme {
    /// Corner radius used for cards and highlighted rows.
    static let cornerRadius: CGFloat = 10
    static let panelWidth: CGFloat = 348
    /// Both time columns share a width so the day reads as a table, not a ragged
    /// list — the whole point of a timetable is that the eye can run down it.
    static let timeColumnWidth: CGFloat = 66

    /// Accent colours for the window of each prayer.
    static func accent(for kind: PrayerKind?) -> Color {
        switch kind {
        case .fajr:      Color(red: 0.36, green: 0.40, blue: 0.72)  // pre-dawn indigo
        case .sunrise:   Color(red: 0.90, green: 0.58, blue: 0.36)  // first light
        case .dhuhr:     Color(red: 0.24, green: 0.60, blue: 0.82)  // high sky
        case .asr:       Color(red: 0.82, green: 0.62, blue: 0.28)  // afternoon gold
        case .maghrib:   Color(red: 0.84, green: 0.42, blue: 0.36)  // sunset
        case .isha:      Color(red: 0.30, green: 0.34, blue: 0.58)  // night
        case .none:      Color.accentColor
        }
    }

    /// Two-stop wash behind the header, in the accent of the current window.
    static func headerGradient(for kind: PrayerKind?) -> LinearGradient {
        let base = accent(for: kind)
        return LinearGradient(
            colors: [base.opacity(0.34), base.opacity(0.10)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Digits in the times column must not reflow as the countdown ticks.
    static let timeFont = Font.system(.callout, design: .default).monospacedDigit()
    static let countdownFont = Font.system(size: 15, weight: .medium, design: .rounded).monospacedDigit()
    static let headlineFont = Font.system(size: 22, weight: .semibold, design: .rounded)
}

/// Formatting helpers shared by the menu bar, the panel and the athan window,
/// so a time never renders one way in one place and differently in another.
struct PrayerFormatter {
    var use24Hour: Bool
    var timeZone: TimeZone

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = use24Hour ? "HH:mm" : "h:mm a"
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        return formatter
    }

    func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// "1h 12m", "12m", "48s" — always the two most significant units, so the
    /// string stays short enough for the menu bar.
    func countdown(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// Longer phrasing for the panel headline.
    func longCountdown(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        switch (hours, minutes) {
        case (0, 0): return "in less than a minute"
        case (0, let m): return "in \(m) minute\(m == 1 ? "" : "s")"
        case (let h, 0): return "in \(h) hour\(h == 1 ? "" : "s")"
        case (let h, let m): return "in \(h)h \(m)m"
        }
    }

    /// Hijri date in the Umm al-Qura calendar, which is the civil calendar of
    /// Saudi Arabia and the one most widely printed on masjid timetables.
    func hijriDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .islamicUmmAlQura)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date) + " AH"
    }

    func gregorianDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter.string(from: date)
    }
}
