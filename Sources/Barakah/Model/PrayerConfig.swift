import Foundation

/// Everything Barakah does for one prayer, on its own. Kept per-prayer because
/// people genuinely want different behaviour at different times — a full adhan at
/// Maghrib, a silent pause at Fajr, a longer warning before Jumu'ah.
public struct PrayerConfig: Codable, Hashable, Sendable {
    /// Play adhan audio when this prayer's time arrives.
    public var athanEnabled: Bool
    /// What to do to media at athan time.
    public var mediaMode: MediaPauseMode
    /// How this prayer's iqama is derived.
    public var iqamaRule: IqamaRule
    /// Notify this many minutes before iqama. Zero disables the reminder.
    public var iqamaReminderMinutes: Int
    /// Also notify at the exact iqama moment.
    public var iqamaAlertEnabled: Bool
    /// Minutes added to (or removed from) the calculated athan time, for masjids
    /// that publish times a couple of minutes off the astronomical value.
    public var athanAdjustmentMinutes: Int

    public init(
        athanEnabled: Bool = true,
        mediaMode: MediaPauseMode = .pause,
        iqamaRule: IqamaRule = .defaultOffset,
        iqamaReminderMinutes: Int = 5,
        iqamaAlertEnabled: Bool = false,
        athanAdjustmentMinutes: Int = 0
    ) {
        self.athanEnabled = athanEnabled
        self.mediaMode = mediaMode
        self.iqamaRule = iqamaRule
        self.iqamaReminderMinutes = iqamaReminderMinutes
        self.iqamaAlertEnabled = iqamaAlertEnabled
        self.athanAdjustmentMinutes = athanAdjustmentMinutes
    }

    /// Sunrise is a marker, not a prayer: shown, never sounded.
    public static let sunriseDefault = PrayerConfig(
        athanEnabled: false,
        mediaMode: .off,
        iqamaRule: .none,
        iqamaReminderMinutes: 0,
        iqamaAlertEnabled: false
    )
}
