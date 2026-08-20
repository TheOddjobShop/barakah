import Testing
import Foundation
@testable import Barakah

/// Tests for bugs that were found in review and fixed. Each one describes the
/// failure it exists to prevent, because the failures were all silent — nothing
/// crashed, nothing logged, the app just quietly did the wrong thing.
@Suite("Regressions")
struct RegressionTests {

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    // MARK: - Notification anchoring

    @Test("Trigger components are anchored to the place's timezone")
    func triggerComponentsCarryTheirZone() throws {
        let riyadh = calendar("Asia/Riyadh")
        let target = Date(timeIntervalSince1970: 1_800_000_000)

        let components = NotificationService.triggerComponents(for: target, in: riyadh)
        #expect(components.timeZone == riyadh.timeZone,
                "without a zone the notification centre resolves these against the user's calendar")

        // The real assertion: resolved by a *different* calendar — which is what
        // UNCalendarNotificationTrigger does — the instant must be unchanged.
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let resolved = try #require(losAngeles.date(from: components))
        #expect(abs(resolved.timeIntervalSince(target)) < 1,
                "a reminder for Riyadh must not drift when the Mac is in Los Angeles")
    }

    @Test("Unanchored components really do drift — the bug this guards")
    func unanchoredComponentsDrift() throws {
        let riyadh = calendar("Asia/Riyadh")
        let target = Date(timeIntervalSince1970: 1_800_000_000)

        let bare = riyadh.dateComponents([.year, .month, .day, .hour, .minute, .second], from: target)
        #expect(bare.timeZone == nil, "Foundation does not carry the zone unless it is requested")

        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let drifted = try #require(losAngeles.date(from: bare))
        #expect(abs(drifted.timeIntervalSince(target)) > 3600,
                "if this ever stops drifting, the anchoring above is no longer load-bearing")
    }

    // MARK: - Event identity

    @Test("An event keeps its identity when its time shifts slightly")
    func keyIsStableAcrossRecomputation() {
        let cal = calendar("Asia/Riyadh")
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        let before = PrayerEvent(prayer: .dhuhr, kind: .athan, fireAt: base)
        // A new location fix a kilometre away moves the time by seconds.
        let after = PrayerEvent(prayer: .dhuhr, kind: .athan, fireAt: base.addingTimeInterval(17))

        #expect(before.key(in: cal) == after.key(in: cal),
                "a shifted time used to mint a new identity, so a just-fired athan looked unfired and sounded twice")
    }

    @Test("The same prayer on different days has different identities")
    func keyDiffersAcrossDays() {
        let cal = calendar("Asia/Riyadh")
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        let tomorrow = today.addingTimeInterval(86_400)

        let a = PrayerEvent(prayer: .fajr, kind: .athan, fireAt: today)
        let b = PrayerEvent(prayer: .fajr, kind: .athan, fireAt: tomorrow)
        #expect(a.key(in: cal) != b.key(in: cal), "tomorrow's Fajr must still be able to fire")
    }

    @Test("Reminder identity ignores the minutes-before setting")
    func reminderKeyIgnoresMinutes() {
        let cal = calendar("Asia/Riyadh")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let five = PrayerEvent(prayer: .asr, kind: .iqamaReminder(minutesBefore: 5), fireAt: at)
        let ten = PrayerEvent(prayer: .asr, kind: .iqamaReminder(minutesBefore: 10), fireAt: at)
        #expect(five.key(in: cal) == ten.key(in: cal),
                "one reminder per prayer per day, whatever the setting was when it fired")
    }

    @Test("The three event kinds never collide")
    func kindsAreDistinct() {
        let cal = calendar("Asia/Riyadh")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let keys = Set([
            PrayerEvent(prayer: .isha, kind: .athan, fireAt: at).key(in: cal),
            PrayerEvent(prayer: .isha, kind: .iqamaReminder(minutesBefore: 5), fireAt: at).key(in: cal),
            PrayerEvent(prayer: .isha, kind: .iqama, fireAt: at).key(in: cal),
        ])
        #expect(keys.count == 3)
    }

    @Test("Identity is measured in the place's day, not the machine's")
    func keyUsesThePlacesDay() {
        // 21:00 in Los Angeles is already the next day in Riyadh.
        let instant = calendar("America/Los_Angeles")
            .date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 21))!
        let event = PrayerEvent(prayer: .isha, kind: .athan, fireAt: instant)

        #expect(event.key(in: calendar("America/Los_Angeles")).hasSuffix("2026-03-15"))
        #expect(event.key(in: calendar("Asia/Riyadh")).hasSuffix("2026-03-16"))
    }
}

/// Exercises `MediaController` without letting it touch the machine's audio:
/// both pause strategies are switched off, so the calls run the whole
/// orchestration path — including the serialisation — and change nothing.
@Suite("Media controller serialisation")
@MainActor
struct MediaControllerTests {

    private func inertSettings() -> SettingsData {
        var settings = SettingsData()
        settings.useMediaRemote = false
        settings.useAppleScript = false
        return settings
    }

    @Test("Concurrent interruptions do not orphan an interruption record")
    func concurrentInterruptsSerialise() async {
        let controller = MediaController()
        let settings = inertSettings()

        // Both used to observe `active == nil` before either had written to it,
        // so the loser's paused players were never resumed — and if the loser
        // had done the muting, output stayed muted through quit.
        async let first = controller.interrupt(mode: .pause, settings: settings)
        async let second = controller.interrupt(mode: .pause, settings: settings)
        _ = await (first, second)

        // With every strategy disabled nothing was actually interrupted, so the
        // controller must hold no record to resume.
        #expect(controller.active == nil)

        await controller.resume()
        #expect(controller.active == nil)
    }

    @Test("A mode of .off is a no-op")
    func offDoesNothing() async {
        let controller = MediaController()
        let interruption = await controller.interrupt(mode: .off, settings: inertSettings())
        #expect(!interruption.didAnything)
        #expect(controller.active == nil)
    }

    @Test("A now-playing description alone is not grounds to resume")
    func descriptionIsNotEvidence() {
        // The exact shape that used to start a paused YouTube tab: a pause was
        // sent, a description came back from the app holding Now Playing, but
        // no audio was ever observed stopping.
        var interruption = MediaInterruption()
        interruption.sentMediaRemotePause = true
        interruption.nowPlayingDescription = "Some Track — Some Artist"
        interruption.mediaRemoteStoppedAudio = false

        #expect(!interruption.didAnything,
                "a pause that stopped nothing is not an interruption worth undoing")
    }

    @Test("Observed audio stopping is grounds to resume")
    func stoppedAudioIsEvidence() {
        var interruption = MediaInterruption()
        interruption.sentMediaRemotePause = true
        interruption.mediaRemoteStoppedAudio = true
        #expect(interruption.didAnything)
        #expect(interruption.isResumable)
    }
}
