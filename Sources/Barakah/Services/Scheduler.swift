import Foundation
import AppKit
import Observation
import OSLog

/// Fires prayer events at the right moment, and keeps firing them correctly
/// across everything macOS does to a long-lived timer.
///
/// The failure modes this exists to survive:
///
/// - **Sleep.** Timers do not fire while the machine is asleep. On wake, the
///   schedule is rebuilt and anything missed is *skipped*, not replayed — an
///   adhan for a prayer that passed two hours ago is worse than no adhan.
/// - **Clock and timezone changes.** Crossing a timezone, or an NTP correction,
///   invalidates every armed time. Both are observed and trigger a rebuild.
/// - **Day rollover.** The horizon is re-derived so tomorrow's Fajr is armed
///   before tonight's Isha has finished.
/// - **A timer that simply does not fire.** A slow heartbeat independently
///   checks for events that came due, so a dropped timer costs seconds, not a
///   prayer.
@MainActor
@Observable
public final class Scheduler {
    /// Events due within the horizon, soonest first.
    public private(set) var upcoming: [PrayerEvent] = []
    /// Today's schedule, ready for display.
    public private(set) var today: DaySchedule?
    /// Tomorrow's, used to show the next prayer once Isha has passed.
    public private(set) var tomorrow: DaySchedule?
    /// The next athan across today and tomorrow.
    public private(set) var nextPrayer: ScheduledPrayer?

    /// Invoked when an event comes due. The coordinator decides what it means.
    public var onEvent: ((PrayerEvent) -> Void)?

    /// How late an event may be and still fire. Beyond this it is treated as
    /// missed — the machine was asleep, or the app was not running.
    private static let grace: TimeInterval = 90
    /// How far ahead events are computed.
    private static let horizon: TimeInterval = 3 * 86_400
    /// Independent safety net in case the precise timer never fires.
    private static let heartbeat: TimeInterval = 30

    private let engine = PrayerTimeEngine()
    private var settings: SettingsData
    private var timer: Timer?
    private var heartbeatTimer: Timer?
    private var firedEventIDs: Set<String> = []
    private var observers: [Any] = []
    private let log = Logger(subsystem: Barakah.subsystem, category: "scheduler")

    public init(settings: SettingsData) {
        self.settings = settings
        installObservers()
        rebuild()
    }

    /// Tear down the timers. Called at app termination; a deinit cannot do this
    /// because the timers are main-actor isolated and deinit is not.
    public func invalidate() {
        timer?.invalidate()
        timer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Apply new settings and rebuild the whole schedule.
    public func update(settings: SettingsData) {
        self.settings = settings
        rebuild()
    }

    /// Recompute schedules, prune stale state, and arm the next timer.
    public func rebuild(now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = settings.activePlace.timeZone

        today = engine.schedule(for: now, settings: settings)
        tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
            .flatMap { engine.schedule(for: $0, settings: settings) }

        nextPrayer = today?.prayers.first { $0.athan > now && $0.kind.isPrayer }
            ?? tomorrow?.prayers.first { $0.kind.isPrayer }

        upcoming = engine.events(after: now.addingTimeInterval(-Self.grace),
                                 horizon: Self.horizon,
                                 settings: settings)

        // Forget fired markers for events now well in the past, so the set cannot
        // grow without bound over a long-running session.
        let cutoff = now.addingTimeInterval(-3600)
        let liveIDs = Set(upcoming.filter { $0.fireAt > cutoff }.map(\.id))
        firedEventIDs.formIntersection(liveIDs)

        arm(now: now)
    }

    /// Fire anything that has come due, then re-arm.
    private func checkDue(now: Date = Date()) {
        var didFire = false
        for event in upcoming where !firedEventIDs.contains(event.id) {
            guard event.fireAt <= now else { break }
            firedEventIDs.insert(event.id)

            let lateness = now.timeIntervalSince(event.fireAt)
            guard lateness <= Self.grace else {
                log.notice("skipping \(event.id, privacy: .public), \(Int(lateness))s late")
                continue
            }
            log.info("firing \(event.id, privacy: .public)")
            onEvent?(event)
            didFire = true
        }

        if didFire {
            rebuild(now: now)
        } else {
            arm(now: now)
        }
    }

    private func arm(now: Date) {
        timer?.invalidate()
        timer = nil

        guard let next = upcoming.first(where: { !firedEventIDs.contains($0.id) && $0.fireAt > now }) else {
            // Nothing pending — the heartbeat will pick up a day rollover.
            startHeartbeatIfNeeded()
            return
        }

        // Cap how far a single timer reaches. A timer armed days out is far more
        // likely to be invalidated by sleep or a clock change than to fire, so
        // the schedule is re-derived at least hourly regardless.
        let fireDate = min(next.fireAt, now.addingTimeInterval(3600))
        let newTimer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDue() }
        }
        newTimer.tolerance = 0.2
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer

        startHeartbeatIfNeeded()
        log.debug("armed for \(fireDate, privacy: .public)")
    }

    private func startHeartbeatIfNeeded() {
        guard heartbeatTimer == nil else { return }
        let beat = Timer(timeInterval: Self.heartbeat, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDue() }
        }
        beat.tolerance = Self.heartbeat / 4
        RunLoop.main.add(beat, forMode: .common)
        heartbeatTimer = beat
    }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default

        // Waking is the single most common way a timer silently dies.
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log.debug("woke from sleep; rebuilding")
                self?.rebuild()
            }
        })

        // A significant clock jump — NTP correction, manual change, or DST.
        observers.append(center.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })

        // Travelling: the times themselves are computed in the place's own zone,
        // but everything displayed is in the system's.
        observers.append(center.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })

        // Midnight: tomorrow becomes today.
        observers.append(center.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
    }
}
