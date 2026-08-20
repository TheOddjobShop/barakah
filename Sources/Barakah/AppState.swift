import Foundation
import AppKit
import Observation
import OSLog

/// The one object that knows what an event *means*.
///
/// Every other service is deliberately ignorant: the scheduler knows when things
/// happen, the audio service knows how to make sound, the media controller knows
/// how to silence players. This type is where those become "at Maghrib, pause
/// Spotify, play the adhan, and put Spotify back when it ends".
@MainActor
@Observable
public final class AppState {
    public let settingsStore: SettingsStore
    public let scheduler: Scheduler
    public let audio: AudioService
    public let media: MediaController
    public let notifications: NotificationService
    public let location: LocationService

    /// Prayers whose athan the user has silenced for today only.
    public private(set) var mutedToday: Set<PrayerKind> = []
    /// Set when every athan is suppressed until this date.
    public private(set) var mutedUntil: Date?
    /// Description of the media Barakah paused, shown in the athan window.
    public private(set) var interruptionSummary: String?

    private var resumeTask: Task<Void, Never>?
    private var mutedTodayDay: Date?
    private let log = Logger(subsystem: Barakah.subsystem, category: "app")

    public var settings: SettingsData { settingsStore.data }

    public init(settingsStore: SettingsStore? = nil) {
        // Constructed here rather than as a default argument: default argument
        // expressions are evaluated outside the actor, and the store is
        // main-actor isolated.
        let store = settingsStore ?? SettingsStore()
        self.settingsStore = store
        self.scheduler = Scheduler(settings: store.data)
        self.audio = AudioService()
        self.media = MediaController()
        self.notifications = NotificationService()
        self.location = LocationService()

        scheduler.onEvent = { [weak self] event in self?.handle(event) }
        audio.onFinish = { [weak self] prayer in self?.athanFinished(prayer) }
        location.onResolve = { [weak self] place in self?.locationResolved(place) }
    }

    /// Called once from the app delegate after the UI exists.
    public func start() async {
        await notifications.refreshAuthorization()
        if location.needsPermission, settings.locationMode == .automatic {
            location.requestPermission()
        } else if settings.locationMode == .automatic {
            location.refresh()
        }
        await notifications.reschedule(settings: settings, engine: PrayerTimeEngine())
        scheduler.rebuild()
    }

    // MARK: - Settings changes

    /// Apply a settings mutation and propagate it everywhere it matters.
    public func updateSettings(_ mutate: (inout SettingsData) -> Void) {
        settingsStore.update(mutate)
        propagateSettingsChange()
    }

    public func updateConfig(for kind: PrayerKind, _ mutate: (inout PrayerConfig) -> Void) {
        settingsStore.updateConfig(for: kind, mutate)
        propagateSettingsChange()
    }

    private func propagateSettingsChange() {
        scheduler.update(settings: settings)
        let snapshot = settings
        Task { await notifications.reschedule(settings: snapshot, engine: PrayerTimeEngine()) }
        if settings.locationMode == .automatic, location.isAuthorized {
            location.refresh()
        }
    }

    private func locationResolved(_ place: PlaceSetting) {
        // Ignore fixes that have not meaningfully moved — prayer times shift by
        // about a minute per 20 km, so sub-kilometre jitter is noise.
        if let existing = settings.resolvedPlace,
           abs(existing.latitude - place.latitude) < 0.01,
           abs(existing.longitude - place.longitude) < 0.01,
           existing.timeZoneIdentifier == place.timeZoneIdentifier {
            return
        }
        updateSettings { $0.resolvedPlace = place }
        log.info("location resolved: \(place.name, privacy: .public)")
    }

    // MARK: - Event handling

    private func handle(_ event: PrayerEvent) {
        guard !isSuppressed(event.prayer) else {
            log.info("suppressed \(event.id, privacy: .public)")
            return
        }

        switch event.kind {
        case .athan:
            Task { await startAthan(for: event.prayer) }
        case .iqamaReminder, .iqama:
            // The visual alert is already scheduled with the notification centre;
            // nothing further is needed here. Resume-at-iqama is handled by the
            // timer started when the athan finished.
            break
        }
    }

    private func startAthan(for prayer: PrayerKind) async {
        let config = settings.config(for: prayer)
        resumeTask?.cancel()
        resumeTask = nil

        // Media is silenced *before* the adhan starts, so the two never overlap.
        if config.mediaMode.pausesPlayers || config.mediaMode.mutesOutput {
            let interruption = await media.interrupt(mode: config.mediaMode, settings: settings)
            interruptionSummary = interruption.summary
        } else {
            interruptionSummary = nil
        }

        if config.athanEnabled {
            audio.play(prayer: prayer, settings: settings)
        } else {
            athanFinished(prayer)
        }
    }

    /// Stop the athan on demand — from the menu bar, the athan window, or a
    /// keyboard shortcut. Resume policy still applies.
    public func stopAthan() {
        audio.stop()
    }

    private func athanFinished(_ prayer: PrayerKind) {
        guard media.active != nil else {
            interruptionSummary = nil
            return
        }

        switch settings.resumeMode {
        case .never:
            media.forget()
            interruptionSummary = nil

        case .afterAthan:
            Task { await media.resume(); interruptionSummary = nil }

        case .afterMinutes(let minutes):
            scheduleResume(after: TimeInterval(minutes * 60))

        case .afterIqama:
            let iqama = scheduler.today?.prayer(prayer)?.iqama
            let delay = iqama.map { max(0, $0.timeIntervalSinceNow) } ?? 0
            scheduleResume(after: delay)
        }
    }

    private func scheduleResume(after delay: TimeInterval) {
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            await self?.media.resume()
            self?.interruptionSummary = nil
        }
    }

    /// Give the user their media back right now, regardless of policy.
    public func resumeMediaNow() {
        resumeTask?.cancel()
        resumeTask = nil
        Task { await media.resume(); interruptionSummary = nil }
    }

    // MARK: - Muting

    public func toggleMuteToday(_ prayer: PrayerKind) {
        pruneMutedToday()
        if mutedToday.contains(prayer) {
            mutedToday.remove(prayer)
        } else {
            mutedToday.insert(prayer)
            mutedTodayDay = Calendar.current.startOfDay(for: Date())
        }
    }

    /// Silence every athan for a while — for a meeting, a flight, a cinema.
    public func mute(for duration: TimeInterval?) {
        mutedUntil = duration.map { Date().addingTimeInterval($0) }
        if duration == nil { mutedUntil = nil }
        if audio.isPlaying { audio.stop() }
    }

    public var isGloballyMuted: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > Date()
    }

    public func isSuppressed(_ prayer: PrayerKind) -> Bool {
        pruneMutedToday()
        return isGloballyMuted || mutedToday.contains(prayer)
    }

    /// "Mute today" means today — clear it once the day has turned over.
    private func pruneMutedToday() {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        if let day = mutedTodayDay, day != startOfToday {
            mutedToday.removeAll()
            mutedTodayDay = nil
        }
    }

    // MARK: - Derived display state

    /// Next prayer, preferring today's remaining prayers and falling back to
    /// tomorrow's Fajr.
    public var nextPrayer: ScheduledPrayer? { scheduler.nextPrayer }

    public var timeUntilNextPrayer: TimeInterval? {
        nextPrayer.map { $0.athan.timeIntervalSinceNow }
    }

    /// The prayer whose window we are currently in.
    public var currentPrayer: ScheduledPrayer? {
        scheduler.today?.currentPrayer(at: Date())
    }

    /// Fraction of the way from the current prayer to the next one, for the arc.
    public var windowProgress: Double {
        guard let next = nextPrayer else { return 0 }
        let start = currentPrayer?.athan
            ?? scheduler.today?.prayers.first?.athan
            ?? next.athan.addingTimeInterval(-3600)
        let total = next.athan.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        return min(1, max(0, elapsed / total))
    }

    public func flush() {
        settingsStore.flush()
    }
}
