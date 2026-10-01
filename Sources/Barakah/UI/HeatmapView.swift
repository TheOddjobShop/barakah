import SwiftUI

/// The prayer heatmap: a year of days as GitHub draws contributions — a column
/// a week, Sunday at the top, each day as green as it was kept. heatmap.py on
/// Linux.
///
/// The tracker window and the desktop widget both draw it, so they show the
/// same thing. Records come from `PrayerTracker.history`, newest first; a
/// day's shade is `PrayerTracker.heat`. Hover a day for what it held; click it
/// to pick it, when there is an `onSelect`.
///
/// A grid of small shapes rather than a Canvas, so each day carries its own
/// tooltip and click.
struct HeatmapView: View {
    let records: [DayRecord]
    let cell: CGFloat
    let gap: CGFloat
    /// Nil follows the colour scheme; the desktop widget forces dark.
    let palette: HeatmapPalette?
    /// The day outlined, "YYYY-MM-DD".
    let selected: String?
    /// Text on the left of the footer, across from the "Less … More" key.
    let footer: String
    let onSelect: ((String) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    init(
        records: [DayRecord],
        cell: CGFloat = 11,
        gap: CGFloat = 3,
        palette: HeatmapPalette? = nil,
        selected: String? = nil,
        footer: String = "",
        onSelect: ((String) -> Void)? = nil
    ) {
        self.records = records
        self.cell = cell
        self.gap = gap
        self.palette = palette
        self.selected = selected
        self.footer = footer
        self.onSelect = onSelect
    }

    // MARK: - Metrics, as heatmap.py has them

    private var step: CGFloat { cell + gap }
    /// The weekday labels' column.
    private var left: CGFloat { (cell * 2.7).rounded() }
    /// The month labels' row.
    private var top: CGFloat { (cell * 1.6).rounded() }
    /// The footer's row.
    private var bottom: CGFloat { (cell * 2.6).rounded() }
    private var radius: CGFloat { max(1.5, cell / 5) }
    private var labelFont: Font { .system(size: max(9, (cell * 0.9).rounded())) }

    private var colours: HeatmapPalette {
        if let palette { return palette }
        return colorScheme == ColorScheme.dark ? HeatmapPalette.dark : HeatmapPalette.light
    }

    // MARK: - Body

    var body: some View {
        let layout = HeatmapLayout(records: records)
        let width = max(0, CGFloat(layout.columns) * step - gap)
        VStack(alignment: .leading, spacing: 0) {
            monthRow(layout, width: width)
            HStack(alignment: .top, spacing: 0) {
                weekdayColumn
                grid(layout)
            }
            footerRow(width: width)
        }
        .fixedSize()
    }

    /// Month labels over the first week that starts in each month, unless it
    /// would crowd the next one, as GitHub does.
    private func monthRow(_ layout: HeatmapLayout, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(layout.months) { label in
                Text(label.name)
                    .font(labelFont)
                    .foregroundStyle(colours.text)
                    .fixedSize()
                    .offset(x: CGFloat(label.column) * step)
            }
        }
        .frame(width: width, height: top, alignment: .leading)
        .padding(.leading, left)
    }

    private var weekdayColumn: some View {
        VStack(alignment: .leading, spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                Text(HeatmapLayout.weekdayLabels[row] ?? "")
                    .font(labelFont)
                    .foregroundStyle(colours.text)
                    .fixedSize()
                    .frame(width: left, height: cell, alignment: .leading)
            }
        }
    }

    private func grid(_ layout: HeatmapLayout) -> some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(0..<layout.columns, id: \.self) { column in
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { row in
                        slot(layout.grid[column][row], today: layout.today)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func slot(_ record: DayRecord?, today: String?) -> some View {
        if let record {
            dayCell(record, isToday: record.day == today)
        } else {
            // Before the first day shown, or after today.
            Color.clear
                .frame(width: cell, height: cell)
        }
    }

    @ViewBuilder
    private func dayCell(_ record: DayRecord, isToday: Bool) -> some View {
        let tip: String = PrayerTracker.describe(record, today: isToday)
            + "\n" + HeatmapLayout.longDate(record.day)
        let tile = RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill(for: record))
            .frame(width: cell, height: cell)
            .overlay {
                if record.day == selected {
                    RoundedRectangle(cornerRadius: radius + 1, style: .continuous)
                        .stroke(colours.selected.opacity(0.9), lineWidth: 1.5)
                        .frame(width: cell + 2, height: cell + 2)
                }
            }
            .contentShape(Rectangle())
            .help(tip)
        // Only a heatmap that picks days takes clicks, so the desktop widget's
        // squares leave a drag to move its window.
        if let onSelect {
            tile.onTapGesture { onSelect(record.day) }
        } else {
            tile
        }
    }

    /// A day with nothing tracked is the empty shade, fainter.
    private func fill(for record: DayRecord) -> Color {
        let levels = colours.levels
        guard let found = PrayerTracker.heat(record) else { return levels[0].opacity(0.45) }
        return levels[min(max(found.level, 0), levels.count - 1)]
    }

    /// What the year held on the left, the key on the right.
    private func footerRow(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(footer)
                .lineLimit(1)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Text("Less")
                HStack(spacing: gap) {
                    ForEach(0..<colours.levels.count, id: \.self) { level in
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(colours.levels[level])
                            .frame(width: cell, height: cell)
                    }
                }
                Text("More")
            }
        }
        .font(labelFont)
        .foregroundStyle(colours.text)
        .frame(width: width, height: bottom)
        .padding(.leading, left)
    }
}

// MARK: - Palettes

/// GitHub's own greens, empty first.
enum HeatmapPalette: Sendable {
    case dark
    case light

    var levels: [Color] {
        switch self {
        case .dark:
            return [Color(hex: 0x161B22), Color(hex: 0x0E4429), Color(hex: 0x006D32),
                    Color(hex: 0x26A641), Color(hex: 0x39D353)]
        case .light:
            return [Color(hex: 0xEBEDF0), Color(hex: 0x9BE9A8), Color(hex: 0x40C463),
                    Color(hex: 0x30A14E), Color(hex: 0x216E39)]
        }
    }

    var text: Color {
        switch self {
        case .dark: return Color(hex: 0x8B949E)
        case .light: return Color(hex: 0x57606A)
        }
    }

    /// The outline round the day picked.
    var selected: Color {
        switch self {
        case .dark: return Color(hex: 0xE6EDF3)
        case .light: return Color(hex: 0x24292F)
        }
    }
}

extension Color {
    /// An sRGB colour from 0xRRGGBB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Layout

/// Where each day of the records goes: a column a week, oldest first, the last
/// being the current week; a row a weekday, Sunday first. Pure date arithmetic
/// on the records' day keys, so it is the same whatever the time zone.
struct HeatmapLayout {
    static let weeks = 53
    /// Enough history to fill every column.
    static let days = weeks * 7

    struct MonthLabel: Identifiable, Hashable {
        let column: Int
        let name: String
        var id: Int { column }
    }

    static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let monthNames = ["January", "February", "March", "April", "May", "June",
                             "July", "August", "September", "October", "November", "December"]
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    /// Rows, Sunday = 0.
    static let weekdayLabels: [Int: String] = [1: "Mon", 3: "Wed", 5: "Fri"]

    let columns: Int
    /// `grid[column][row]`; nil before the first record and after today.
    let grid: [[DayRecord?]]
    /// The labels to draw, crowded ones already dropped.
    let months: [MonthLabel]
    /// The newest record's day.
    let today: String?

    init(records: [DayRecord], weeks: Int = HeatmapLayout.weeks) {
        let calendar = HeatmapLayout.utc
        var columns = 0
        var grid: [[DayRecord?]] = []
        var months: [MonthLabel] = []
        let today = records.first?.day

        if let key = today,
           let todayDate = HeatmapLayout.parse(key),
           let start = calendar.date(byAdding: .day, value: -(weeks * 7 - 7), to: todayDate) {
            let sinceSunday = calendar.component(.weekday, from: start) - 1
            if let firstSunday = calendar.date(byAdding: .day, value: -sinceSunday, to: start) {
                columns = HeatmapLayout.daysBetween(firstSunday, todayDate) / 7 + 1
                grid = [[DayRecord?]](
                    repeating: [DayRecord?](repeating: nil, count: 7), count: max(0, columns))
                for record in records {
                    guard let date = HeatmapLayout.parse(record.day) else { continue }
                    let offset = HeatmapLayout.daysBetween(firstSunday, date)
                    guard offset >= 0 else { continue }
                    let column = offset / 7
                    guard column < columns else { continue }
                    grid[column][offset % 7] = record
                }

                var labels: [MonthLabel] = []
                var previous: Int?
                for column in 0..<max(0, columns) {
                    guard let sunday = calendar.date(byAdding: .day, value: 7 * column, to: firstSunday) else {
                        continue
                    }
                    let month = calendar.component(.month, from: sunday)
                    if month != previous, (1...12).contains(month) {
                        labels.append(MonthLabel(column: column, name: HeatmapLayout.monthAbbreviations[month - 1]))
                        previous = month
                    }
                }
                for (index, label) in labels.enumerated() {
                    let following = index + 1 < labels.count ? labels[index + 1].column : columns + 3
                    if following - label.column < 3 { continue }
                    months.append(label)
                }
            }
        }

        self.columns = max(0, columns)
        self.grid = grid
        self.months = months
        self.today = today
    }

    /// Day keys are calendar dates, so they are counted in UTC, where every
    /// day is 24 hours long.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        return calendar
    }()

    /// "YYYY-MM-DD" as midnight UTC.
    static func parse(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func daysBetween(_ from: Date, _ to: Date) -> Int {
        Int((to.timeIntervalSince(from) / 86_400).rounded())
    }

    /// "Friday, 3 April 2026" — the same words whatever the user's locale, as
    /// on Linux.
    static func longDate(_ key: String) -> String {
        guard let parsed = parse(key) else { return key }
        let parts = utc.dateComponents([.year, .month, .day, .weekday], from: parsed)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let weekday = parts.weekday,
              (1...12).contains(month), (1...7).contains(weekday) else { return key }
        return "\(weekdayNames[weekday - 1]), \(day) \(monthNames[month - 1]) \(year)"
    }
}
