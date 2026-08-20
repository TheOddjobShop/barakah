import Foundation

/// How the iqama time for a prayer is derived.
///
/// Iqama is not calculable from astronomy — it is whatever the local masjid decided.
/// Two shapes cover essentially every masjid in practice: a fixed offset after the
/// adhan ("Athan + 10"), or a fixed wall-clock time ("Dhuhr is always 1:30").
public enum IqamaRule: Codable, Hashable, Sendable {
    case none
    case offset(minutes: Int)
    case fixed(hour: Int, minute: Int)

    public static let defaultOffset = IqamaRule.offset(minutes: 10)

    /// Resolve the iqama moment for a given adhan time, in the given calendar.
    public func resolve(athan: Date, calendar: Calendar) -> Date? {
        switch self {
        case .none:
            return nil
        case .offset(let minutes):
            return calendar.date(byAdding: .minute, value: minutes, to: athan)
        case .fixed(let hour, let minute):
            var comps = calendar.dateComponents([.year, .month, .day], from: athan)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard let fixed = calendar.date(from: comps) else { return nil }
            // A fixed time that lands before the adhan belongs to the next day
            // (only realistically possible for Isha near midnight).
            if fixed < athan {
                return calendar.date(byAdding: .day, value: 1, to: fixed)
            }
            return fixed
        }
    }

    public var isEnabled: Bool {
        if case .none = self { return false }
        return true
    }

    /// Short human description for the settings UI.
    public func describe(formatter: DateFormatter) -> String {
        switch self {
        case .none:
            return "Off"
        case .offset(let minutes):
            return "Athan + \(minutes) min"
        case .fixed(let hour, let minute):
            guard let date = Calendar.current.date(from: DateComponents(
                year: 2000, month: 1, day: 1, hour: hour, minute: minute)) else {
                return String(format: "%02d:%02d", hour, minute)
            }
            return formatter.string(from: date)
        }
    }
}
