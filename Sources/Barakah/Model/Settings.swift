import Foundation
import Observation
import Adhan

/// How the menu bar item presents itself.
public enum MenuBarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Icon plus "Asr in 1h 12m".
    case countdown
    /// Icon plus the next prayer's clock time.
    case nextTime
    /// Icon plus the next prayer's name.
    case nextName
    /// Icon only.
    case iconOnly

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .countdown: "Countdown to next prayer"
        case .nextTime: "Next prayer time"
        case .nextName: "Next prayer name"
        case .iconOnly: "Icon only"
        }
    }
}

/// Serialisable form of everything the user can configure. Kept as a plain
/// `Codable` struct so persistence is a single encode, and the observable store
/// below owns exactly one of them.
public struct SettingsData: Codable, Hashable, Sendable {
    // MARK: Location
    public var locationMode: LocationMode = .automatic
    public var manualPlace: PlaceSetting = .makkah
    /// Last place resolved from CoreLocation, cached so the app has real times
    /// immediately on launch instead of waiting on a fix.
    public var resolvedPlace: PlaceSetting?

    // MARK: Calculation
    public var calculationMethod: CalculationMethod = .muslimWorldLeague
    public var madhab: Madhab = .shafi
    public var highLatitudeRule: HighLatitudeRule?
    /// Overrides the method's Fajr angle when set.
    public var customFajrAngle: Double?
    /// Overrides the method's Isha angle when set.
    public var customIshaAngle: Double?

    // MARK: Per prayer
    public var prayerConfigs: [PrayerKind: PrayerConfig] = SettingsData.defaultPrayerConfigs
    /// Friday Dhuhr replacement, when the masjid runs Jumu'ah on its own clock.
    public var jumuahEnabled: Bool = false
    public var jumuahIqamaRule: IqamaRule = .fixed(hour: 13, minute: 30)
    public var jumuahReminderMinutes: Int = 15

    // MARK: Audio
    public var athanSound: AthanSound = .chime
    /// Fajr has an extra line in the adhan, so it usually wants its own recording.
    public var fajrAthanSound: AthanSound?
    public var athanVolume: Double = 0.8
    /// Stop the adhan automatically after this many seconds. Zero plays it whole.
    public var athanMaxSeconds: Int = 0
    /// Duck other audio rather than pausing during playback of the athan.
    public var showAthanWindow: Bool = true

    // MARK: Media
    public var resumeMode: MediaResumeMode = .never
    /// Use the private MediaRemote route (the same channel as the ⏯ media key).
    public var useMediaRemote: Bool = true
    /// Use per-app AppleScript control for scriptable players.
    public var useAppleScript: Bool = true
    /// Bundle identifiers the user has excluded from pausing.
    public var mediaExcludedBundleIDs: [String] = []

    // MARK: Notifications
    public var notifyAtAthan: Bool = true
    public var notificationSoundEnabled: Bool = false

    // MARK: General
    public var menuBarStyle: MenuBarStyle = .countdown
    public var use24HourClock: Bool = false
    public var showHijriDate: Bool = true
    public var showSunrise: Bool = true
    public var launchAtLogin: Bool = false
    public var hasCompletedOnboarding: Bool = false

    public init() {}

    public static var defaultPrayerConfigs: [PrayerKind: PrayerConfig] {
        var configs: [PrayerKind: PrayerConfig] = [:]
        for kind in PrayerKind.allCases {
            configs[kind] = kind.isPrayer ? PrayerConfig() : .sunriseDefault
        }
        return configs
    }

    public func config(for kind: PrayerKind) -> PrayerConfig {
        prayerConfigs[kind] ?? (kind.isPrayer ? PrayerConfig() : .sunriseDefault)
    }

    /// The place times should currently be computed for.
    public var activePlace: PlaceSetting {
        switch locationMode {
        case .manual: manualPlace
        case .automatic: resolvedPlace ?? manualPlace
        }
    }

    /// adhan-swift parameters assembled from the calculation settings.
    public var calculationParameters: CalculationParameters {
        var params = calculationMethod.params
        params.madhab = madhab
        if let highLatitudeRule { params.highLatitudeRule = highLatitudeRule }
        if let customFajrAngle { params.fajrAngle = customFajrAngle }
        if let customIshaAngle {
            params.ishaAngle = customIshaAngle
            params.ishaInterval = 0
        }
        return params
    }

    /// The iqama rule in force for a prayer on a given weekday, honouring the
    /// Jumu'ah override (weekday 6 is Friday in the Gregorian calendar).
    public func effectiveIqamaRule(for kind: PrayerKind, isFriday: Bool) -> IqamaRule {
        if kind == .dhuhr, isFriday, jumuahEnabled { return jumuahIqamaRule }
        return config(for: kind).iqamaRule
    }

    public func effectiveReminderMinutes(for kind: PrayerKind, isFriday: Bool) -> Int {
        if kind == .dhuhr, isFriday, jumuahEnabled { return jumuahReminderMinutes }
        return config(for: kind).iqamaReminderMinutes
    }

    /// Sound to play for a given prayer.
    public func sound(for kind: PrayerKind) -> AthanSound {
        if kind == .fajr, let fajrAthanSound { return fajrAthanSound }
        return athanSound
    }
}

// MARK: - Codable conformances for adhan-swift enums

// adhan-swift already declares Codable on these; only Sendable needs asserting,
// and each is a payload-free enum so it is trivially safe to share.
extension CalculationMethod: @unchecked @retroactive Sendable {}
extension Madhab: @unchecked @retroactive Sendable {}
extension HighLatitudeRule: @unchecked @retroactive Sendable {}

extension CalculationMethod {
    public var label: String {
        switch self {
        case .muslimWorldLeague: "Muslim World League"
        case .egyptian: "Egyptian General Authority"
        case .karachi: "University of Islamic Sciences, Karachi"
        case .ummAlQura: "Umm al-Qura, Makkah"
        case .dubai: "Dubai"
        case .moonsightingCommittee: "Moonsighting Committee"
        case .northAmerica: "ISNA (North America)"
        case .kuwait: "Kuwait"
        case .qatar: "Qatar"
        case .singapore: "Singapore"
        case .tehran: "Tehran"
        case .turkey: "Diyanet (Turkey)"
        case .other: "Custom"
        }
    }

    /// Methods offered in the picker, in a sensible order. `.other` is implied by
    /// setting a custom angle, so it is not listed.
    public static var selectable: [CalculationMethod] {
        [.muslimWorldLeague, .northAmerica, .egyptian, .karachi, .ummAlQura,
         .dubai, .qatar, .kuwait, .singapore, .turkey, .tehran, .moonsightingCommittee]
    }
}

extension Madhab {
    public var label: String {
        switch self {
        case .shafi: "Shafi'i, Maliki, Hanbali"
        case .hanafi: "Hanafi"
        }
    }
    /// The only thing madhab changes here is when Asr begins.
    public var asrDescription: String {
        switch self {
        case .shafi: "Asr when a shadow equals an object's length"
        case .hanafi: "Asr when a shadow equals twice an object's length"
        }
    }
}

extension HighLatitudeRule {
    public var label: String {
        switch self {
        case .middleOfTheNight: "Middle of the night"
        case .seventhOfTheNight: "One seventh of the night"
        case .twilightAngle: "Twilight angle"
        }
    }
    public var detail: String {
        switch self {
        case .middleOfTheNight: "Fajr and Isha never cross the midpoint of the night."
        case .seventhOfTheNight: "Night is split in sevenths; Isha gets one, Fajr one."
        case .twilightAngle: "Night is divided in proportion to the method's angles."
        }
    }
}
