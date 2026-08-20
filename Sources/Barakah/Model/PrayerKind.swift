import Foundation
import Adhan

/// The six daily time markers Barakah tracks. Sunrise is not a prayer — it is the
/// end of Fajr's window — so it is displayed but never carries an adhan or iqama.
public enum PrayerKind: String, Codable, CaseIterable, Identifiable, Sendable, CodingKeyRepresentable {
    case fajr, sunrise, dhuhr, asr, maghrib, isha

    public var id: String { rawValue }

    /// Ordering used everywhere the day is listed top-to-bottom.
    public static var displayOrder: [PrayerKind] { allCases }

    /// Prayers that can sound an adhan and hold an iqama time.
    public static var prayers: [PrayerKind] { allCases.filter(\.isPrayer) }

    public var isPrayer: Bool { self != .sunrise }

    public var name: String {
        switch self {
        case .fajr: "Fajr"
        case .sunrise: "Sunrise"
        case .dhuhr: "Dhuhr"
        case .asr: "Asr"
        case .maghrib: "Maghrib"
        case .isha: "Isha"
        }
    }

    public var arabicName: String {
        switch self {
        case .fajr: "الفجر"
        case .sunrise: "الشروق"
        case .dhuhr: "الظهر"
        case .asr: "العصر"
        case .maghrib: "المغرب"
        case .isha: "العشاء"
        }
    }

    /// SF Symbol that reads as the sun's position at that hour.
    public var symbolName: String {
        switch self {
        case .fajr: "sunrise"
        case .sunrise: "sun.horizon"
        case .dhuhr: "sun.max"
        case .asr: "sun.min"
        case .maghrib: "sunset"
        case .isha: "moon.stars"
        }
    }

    /// Bridge to adhan-swift's own enum.
    public var adhanPrayer: Adhan.Prayer {
        switch self {
        case .fajr: .fajr
        case .sunrise: .sunrise
        case .dhuhr: .dhuhr
        case .asr: .asr
        case .maghrib: .maghrib
        case .isha: .isha
        }
    }
}
