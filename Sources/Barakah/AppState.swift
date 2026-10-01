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
    /// What the user has sworn they prayed, kept for the tracker and the lock.
    public let prayerLog: PrayerLogStore

    /// Prayers the user has silenced, each mapped to the day it was silenced
    /// for.
    ///
    /// Stored as a day rather than a bare set so that reading it is a pure
    /// comparison. The old set-plus-prune arrangement meant the popover could
    /// show a stale mute from yesterday, and clicking "unmute" would prune
    /// first, find nothing, and *mute* today's prayer instead.
    public private(set) var mutedDays: [PrayerKind: Date] = [:]
    /// Set when every athan is suppressed until this date.
    public private(set) var mutedUntil: Date?
    /// Description of the media Barakah paused, shown in the athan window.
    public private(set) var interruptionSummary: String?
    /// The prayer lock, re-derived every couple of seconds and after anything
    /// that could change it. It is state, not an event: asking often is what
    /// makes a restart, a wake or a clock change bring it back. Independent of
    /// athan muting, which silences sound only.
    public private(set) var lock: LockState = LockState()

    /// Posted whenever the lock starts, ends or moves to another prayer, so
    /// the overlay appears on the instant rather than on the next refresh.
    public static let lockChanged = Notification.Name("dev.justin06lee.barakah.lockChanged")
    /// Posted when the desktop widget's settings change, so it appears or goes
    /// on the instant rather than on the menu bar's next refresh.
    public static let widgetChanged = Notification.Name("dev.justin06lee.barakah.widgetChanged")
    /// How often the lock is re-derived.
    private static let lockCheckInterval: TimeInterval = 2
    /// The window the lock preview is showing, if one is up. A preview records
    /// nothing, pauses nothing and does not block quitting.
    public private(set) var lockPreview: PrayerWindow?
    /// How long a preview stays up unless closed.
    private static let previewSeconds: TimeInterval = 60
    /// Set when an athan's resume came due while the lock was up. The lock
    /// keeps media paused, so the resume waits for the lock to lift.
    public private(set) var resumeDeferredByLock: Bool = false

    private var resumeTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var dayObserver: Any?
    private var lockTimer: Timer?
    private var lockPauseTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private let engine = PrayerTimeEngine()
    private let log = Logger(subsystem: Barakah.subsystem, category: "app")

    public var settings: SettingsData { settingsStore.data }

    /// Start of today in the *place's* timezone, which is the day prayers are
    /// measured in — the system's day drifts from it when tracking another city.
    private var startOfPlaceDay: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = settings.activePlace.timeZone
        return calendar.startOfDay(for: Date())
    }

    public init(settingsStore: SettingsStore? = nil, prayerLog: PrayerLogStore? = nil) {
        // Constructed here rather than as a default argument: default argument
        // expressions are evaluated outside the actor, and the store is
        // main-actor isolated.
        let store = settingsStore ?? SettingsStore()
        self.settingsStore = store
        self.prayerLog = prayerLog ?? PrayerLogStore()
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
        // A previous run may have died mid-athan with the output muted.
        OutputMuter.shared.recoverIfNeeded()

        // Before anything that awaits: a lock that was due while the app was
        // not running must come back at launch, not after a permission prompt.
        checkLock()
        startLockChecks()

        // The notification horizon is only three days long, so something has to
        // roll it forward or reminders silently stop on a machine that simply
        // stays logged in — which is the normal case for a login item.
        scheduler.onRebuild = { [weak self] in self?.refreshNotifications() }
        dayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNotifications(force: true) }
        }

        await notifications.refreshAuthorization()
        if location.needsPermission, settings.locationMode == .automatic {
            location.requestPermission()
        } else if settings.locationMode == .automatic {
            location.refresh()
        }
        refreshNotifications(force: true)
        scheduler.rebuild()
    }

    // MARK: - Settings changes

    /// Apply a settings mutation and propagate it everywhere it matters.
    public func updateSettings(_ mutate: (inout SettingsData) -> Void) {
        let widgetBefore = settings.widget
        settingsStore.update(mutate)
        propagateSettingsChange()
        if settings.widget != widgetBefore {
            NotificationCenter.default.post(name: Self.widgetChanged, object: nil)
        }
    }

    public func updateConfig(for kind: PrayerKind, _ mutate: (inout PrayerConfig) -> Void) {
        settingsStore.updateConfig(for: kind, mutate)
        propagateSettingsChange()
    }

    private func propagateSettingsChange() {
        scheduler.update(settings: settings)
        refreshNotifications(force: true)
        checkLock()
        if settings.locationMode == .automatic, location.isAuthorized {
            location.refresh()
        }
    }

    /// When the pending notifications were last rewritten.
    private var lastNotificationRefresh: Date?

    /// Rewrite the pending notifications.
    ///
    /// Rebuilds happen often — every wake, clock change and settings edit — and
    /// rewriting forty-odd notifications each time is pointless, so unforced
    /// calls are throttled. Forced calls come from the things that genuinely
    /// change what should be pending: a settings edit, a day rollover, or the
    /// user silencing a prayer.
    public func refreshNotifications(force: Bool = false) {
        if !force, let last = lastNotificationRefresh,
           Date().timeIntervalSince(last) < 6 * 3600 { return }
        lastNotificationRefresh = Date()

        let snapshot = settings
        let mutedSnapshot = mutedDays
        let mutedUntilSnapshot = mutedUntil
        let placeDay = startOfPlaceDay

        // Only one reschedule may be in flight: each begins by removing every
        // pending request, so two interleaving could leave the older run's
        // remaining adds behind, alerting at the previous times.
        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            guard let self else { return }
            await self.notifications.reschedule(
                settings: snapshot,
                engine: PrayerTimeEngine()
            ) { prayer, fireAt in
                // Silencing must reach the notifications too. Otherwise
                // "silence athans for an hour" still popped a time-sensitive
                // banner during the meeting it was silenced for.
                if let until = mutedUntilSnapshot, fireAt <= until { return true }
                return mutedSnapshot[prayer] == placeDay
            }
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
        // A new athan supersedes a resume the lock was holding back; resuming
        // it later would undo this athan's own pause.
        resumeDeferredByLock = false

        // Media is silenced *before* the adhan starts, so the two never overlap.
        if config.mediaMode.pausesPlayers || config.mediaMode.mutesOutput {
            let interruption = await media.interrupt(mode: config.mediaMode, settings: settings)
            interruptionSummary = interruption.summary
        } else {
            interruptionSummary = nil
        }

        // An athan that is "enabled" but set to Silent makes no more sound than
        // a disabled one, and must be treated the same way — otherwise media
        // pauses and resumes within the same runloop tick.
        if config.athanEnabled, !settings.sound(for: prayer).isSilent {
            audio.play(prayer: prayer, settings: settings)
        } else {
            // Media was paused but no athan will play, so "resume when the athan
            // ends" has nothing to hang off and would fire in the same instant —
            // pausing and unpausing so fast the user only sees a glitch. Give the
            // silence roughly the length an athan would have had instead.
            athanFinished(prayer, silentAthanLength: Self.silentAthanLength)
        }
    }

    /// How long a pause lasts when a prayer silences media without sounding an
    /// athan. Two minutes is about the length of a spoken adhan.
    private static let silentAthanLength: TimeInterval = 120

    /// Stop the athan on demand — from the menu bar, the athan window, or a
    /// keyboard shortcut. Resume policy still applies.
    public func stopAthan() {
        audio.stop()
    }

    private func athanFinished(_ prayer: PrayerKind, silentAthanLength: TimeInterval = 0) {
        guard media.active != nil else {
            interruptionSummary = nil
            return
        }

        switch settings.resumeMode {
        case .never:
            media.forget()
            interruptionSummary = nil

        case .afterAthan:
            if silentAthanLength > 0 {
                scheduleResume(after: silentAthanLength)
            } else {
                Task { await resumeUnlessLocked() }
            }

        case .afterMinutes(let minutes):
            scheduleResume(after: TimeInterval(minutes * 60) + silentAthanLength)

        case .afterIqama:
            // With no iqama rule there is nothing to wait for, so fall back to
            // the silent-athan length rather than resuming instantly.
            let iqama = scheduler.today?.prayer(prayer)?.iqama
            let delay = iqama.map { max(0, $0.timeIntervalSinceNow) } ?? silentAthanLength
            scheduleResume(after: max(delay, silentAthanLength))
        }
    }

    private func scheduleResume(after delay: TimeInterval) {
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            await self?.resumeUnlessLocked()
        }
    }

    /// The athan's resume, unless the prayer lock is up: then it is deferred
    /// until the lock lifts, and the interruption record is kept.
    private func resumeUnlessLocked() async {
        if lock.active != nil {
            resumeDeferredByLock = true
            log.info("media resume deferred by the prayer lock")
            return
        }
        await media.resume()
        interruptionSummary = nil
    }

    /// Give the user their media back right now, regardless of policy — and of
    /// the lock, though while it is up the next check pauses it again.
    public func resumeMediaNow() {
        resumeTask?.cancel()
        resumeTask = nil
        resumeDeferredByLock = false
        Task { await media.resume(); interruptionSummary = nil }
    }

    // MARK: - Muting

    /// Whether this prayer's athan is silenced for today.
    public func isMutedToday(_ prayer: PrayerKind) -> Bool {
        mutedDays[prayer] == startOfPlaceDay
    }

    public func toggleMuteToday(_ prayer: PrayerKind) {
        if isMutedToday(prayer) {
            mutedDays[prayer] = nil
        } else {
            mutedDays[prayer] = startOfPlaceDay
        }
        refreshNotifications(force: true)
    }

    /// Silence every athan for a while — for a meeting, a flight, a cinema.
    public func mute(for duration: TimeInterval?) {
        mutedUntil = duration.map { Date().addingTimeInterval($0) }
        if audio.isPlaying { audio.stop() }
        refreshNotifications(force: true)
    }

    public var isGloballyMuted: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > Date()
    }

    public func isSuppressed(_ prayer: PrayerKind) -> Bool {
        isGloballyMuted || isMutedToday(prayer)
    }

    // MARK: - Prayer tracker and lock

    private func startLockChecks() {
        lockTimer?.invalidate()
        let timer = Timer(timeInterval: Self.lockCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLock() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        lockTimer = timer
    }

    public func stopLockChecks() {
        lockTimer?.invalidate()
        lockTimer = nil
    }

    /// Re-derive the lock for this instant, and while it is up keep every
    /// player paused.
    public func checkLock() {
        let state = PrayerTracker.lockState(now: Date(), settings: settings, log: prayerLog.log, engine: engine)
        if state != lock {
            let wasActive = lock.active != nil
            let activeChanged = state.active != lock.active
            if activeChanged {
                let description = state.active.map { "on for \($0.kind.name)" } ?? "off"
                log.info("prayer lock \(description, privacy: .public)")
            }
            lock = state
            // The real lock takes over from a preview.
            if state.active != nil, lockPreview != nil {
                previewTask?.cancel()
                previewTask = nil
                lockPreview = nil
            }
            if activeChanged {
                NotificationCenter.default.post(name: Self.lockChanged, object: nil)
            }
            if wasActive, state.active == nil {
                lockLifted()
            }
        }
        if lock.active != nil {
            pauseMediaForLock()
        }
    }

    /// One pass at a time: an Apple Event to a hung player can outlast the
    /// two-second tick, and passes must not pile up behind it.
    private func pauseMediaForLock() {
        guard lockPauseTask == nil else { return }
        let snapshot = settings
        lockPauseTask = Task { [weak self] in
            guard let self else { return }
            let paused = await self.media.pausePlaying(settings: snapshot)
            if paused > 0 {
                self.interruptionSummary = self.media.active?.summary
            }
            self.lockPauseTask = nil
        }
    }

    /// Media the lock paused stays paused; only a resume the lock held back
    /// is carried out now.
    private func lockLifted() {
        guard resumeDeferredByLock else { return }
        resumeDeferredByLock = false
        let pending = lockPauseTask
        Task { [weak self] in
            // Let a pause pass still in flight land first, or it could record
            // a fresh interruption after this resume.
            await pending?.value
            guard let self, self.lock.active == nil else { return }
            await self.media.resume()
            self.interruptionSummary = nil
        }
    }

    /// Show the cover as it will look, for the prayer whose time it is (or the
    /// next one today), recording nothing. Refused while the real lock is up;
    /// lifts by itself after a minute.
    public func previewLock() {
        guard lock.active == nil, lockPreview == nil else { return }
        let now = Date()
        let found = currentWindow
            ?? PrayerTracker.windows(for: now, settings: settings, engine: engine).first(where: { $0.start > now })
        guard let window = found else { return }
        lockPreview = window
        NotificationCenter.default.post(name: Self.lockChanged, object: nil)
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppState.previewSeconds))
            guard !Task.isCancelled else { return }
            self?.endLockPreview()
        }
    }

    public func endLockPreview() {
        previewTask?.cancel()
        previewTask = nil
        guard lockPreview != nil else { return }
        lockPreview = nil
        NotificationCenter.default.post(name: Self.lockChanged, object: nil)
    }

    /// The prayer whose time it is now, if any.
    public var currentWindow: PrayerWindow? {
        PrayerTracker.window(at: Date(), settings: settings, engine: engine)
    }

    public func status(of window: PrayerWindow) -> PrayerStatus {
        PrayerTracker.status(of: window, in: prayerLog.log, now: Date())
    }

    /// The oath. Inside the window it is on time; after it, qada.
    public func confirmPrayed(_ window: PrayerWindow) {
        let now = Date()
        prayerLog.record(
            day: window.day, kind: window.kind,
            status: PrayerTracker.statusForRecord(window, now: now), at: now)
        checkLock()
    }

    /// Correct the record from the tracker: qada, excused, or cleared.
    public func setStatus(day: String, prayer: PrayerKind, status: PrayerStatus?) {
        if let status {
            prayerLog.record(day: day, kind: prayer, status: status)
        } else {
            prayerLog.clear(day: day, kind: prayer)
        }
        checkLock()
    }

    public func history(days: Int) -> [DayRecord] {
        PrayerTracker.history(log: prayerLog.log, settings: settings, now: Date(), days: days, engine: engine)
    }

    public func updateLock(_ mutate: (inout PrayerLockSettings) -> Void) {
        updateSettings { $0.updateLock(mutate) }
    }

    /// Show or hide the prayer heatmap on the desktop.
    public func updateWidget(_ mutate: (inout TrackerWidgetSettings) -> Void) {
        updateSettings { $0.updateWidget(mutate) }
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
