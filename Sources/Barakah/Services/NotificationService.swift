import Foundation
import UserNotifications
import Observation
import OSLog

/// Delivers the visual side of Barakah's alerts.
///
/// Notifications are always *pre-scheduled* with calendar triggers rather than
/// posted by the in-app timer. Scheduled local notifications fire whether or not
/// the app is running, so an iqama reminder survives a quit, a crash, or a
/// machine that woke up two minutes ago. Audio and media control stay on the
/// live timer, which cleanly avoids the same alert arriving twice.
@MainActor
@Observable
public final class NotificationService {
    public private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// macOS allows 64 pending notifications per app; three days of a five-prayer
    /// schedule at three alerts each is 45, which stays comfortably inside that.
    private static let horizonDays = 3
    private static let pendingLimit = 60

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: Barakah.subsystem, category: "notify")

    public init() {}

    public func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    public func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            return granted
        } catch {
            log.error("notification authorization failed: \(error.localizedDescription)")
            await refreshAuthorization()
            return false
        }
    }

    public var isAuthorized: Bool {
        authorization == .authorized || authorization == .provisional
    }

    /// Replace all pending notifications with those implied by current settings.
    ///
    /// Called on launch, on any settings change, on location change, and once a
    /// day so the horizon keeps rolling forward.
    public func reschedule(settings: SettingsData, engine: PrayerTimeEngine, now: Date = Date()) async {
        center.removeAllPendingNotificationRequests()
        guard isAuthorized else { return }

        let horizon = TimeInterval(Self.horizonDays * 86_400)
        let events = engine.events(after: now, horizon: horizon, settings: settings)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = settings.activePlace.timeZone
        let formatter = DateFormatter()
        formatter.timeZone = settings.activePlace.timeZone
        formatter.dateFormat = settings.use24HourClock ? "HH:mm" : "h:mm a"

        var scheduled = 0
        for event in events where scheduled < Self.pendingLimit {
            guard let content = content(for: event, settings: settings, formatter: formatter) else { continue }

            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: event.fireAt
            )
            let request = UNNotificationRequest(
                identifier: event.id,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            do {
                try await center.add(request)
                scheduled += 1
            } catch {
                log.error("failed to schedule \(event.id, privacy: .public): \(error.localizedDescription)")
            }
        }
        log.info("scheduled \(scheduled) notifications over \(Self.horizonDays) days")
    }

    public func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }

    private func content(
        for event: PrayerEvent,
        settings: SettingsData,
        formatter: DateFormatter
    ) -> UNMutableNotificationContent? {
        let config = settings.config(for: event.prayer)
        let content = UNMutableNotificationContent()

        switch event.kind {
        case .athan:
            guard settings.notifyAtAthan else { return nil }
            content.title = "\(event.prayer.name) — \(formatter.string(from: event.fireAt))"
            content.body = config.iqamaRule.isEnabled
                ? "It is time for \(event.prayer.name)."
                : "It is time for \(event.prayer.name). \(event.prayer.arabicName)"
            content.interruptionLevel = .timeSensitive

        case .iqamaReminder(let minutes):
            content.title = "\(event.prayer.name) iqama in \(minutes) min"
            let iqamaAt = Calendar.current.date(byAdding: .minute, value: minutes, to: event.fireAt)
            content.body = iqamaAt.map { "Iqama at \(formatter.string(from: $0))." }
                ?? "Iqama is coming up."
            content.interruptionLevel = .timeSensitive

        case .iqama:
            content.title = "\(event.prayer.name) iqama"
            content.body = "The iqama has been called."
            content.interruptionLevel = .timeSensitive
        }

        // The app plays the athan itself, so the notification stays silent unless
        // the user explicitly wants a system sound alongside it.
        content.sound = settings.notificationSoundEnabled ? .default : nil
        content.threadIdentifier = event.prayer.rawValue
        return content
    }
}
