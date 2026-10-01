import Foundation
import Observation
import OSLog

/// Owns the prayer log and its file, prayer-log.json beside settings.json.
///
/// Each record is written at once rather than debounced like settings: they
/// come a few times a day, and an oath lost to a crash is a lock that comes
/// back.
@MainActor
@Observable
public final class PrayerLogStore {
    public private(set) var log: PrayerLog

    private let url: URL
    private let logger = Logger(subsystem: Barakah.subsystem, category: "prayer-log")

    public init(url: URL = PrayerLogStore.defaultURL, now: Date = Date()) {
        self.url = url
        switch PrayerLogStore.load(from: url, logger: Logger(subsystem: Barakah.subsystem, category: "prayer-log")) {
        case .loaded(let existing):
            self.log = existing
        case .unreadable:
            // Unreadable is not absent: never overwrite it at load.
            self.log = PrayerLog(since: now)
        case .fresh:
            // Tracking starts now: earlier prayers are untracked, not missed.
            self.log = PrayerLog(since: now)
            save()
        }
    }

    public func record(day: String, kind: PrayerKind, status: PrayerStatus, at: Date = Date()) {
        log.record(day: day, kind: kind, status: status, at: at)
        save()
    }

    public func clear(day: String, kind: PrayerKind) {
        log.clear(day: day, kind: kind)
        save()
    }

    // MARK: - Persistence

    nonisolated public static var defaultURL: URL {
        SettingsStore.defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent("prayer-log.json")
    }

    private enum Loaded {
        case loaded(PrayerLog)
        /// Missing, or set aside as corrupt: start a new log and write it.
        case fresh
        /// There, but could not be read or moved aside.
        case unreadable
    }

    private static func load(from url: URL, logger: Logger) -> Loaded {
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) { return .fresh }
            logger.error("prayer log unreadable: \(error.localizedDescription)")
            return .unreadable
        }
        do {
            return .loaded(try JSONDecoder().decode(PrayerLog.self, from: raw))
        } catch {
            logger.error("prayer log unreadable, starting a new one: \(error.localizedDescription)")
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            do {
                try FileManager.default.moveItem(at: url, to: backup)
            } catch {
                return .unreadable
            }
            return .fresh
        }
    }

    /// Write the whole log, atomically.
    public func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(log)
            try encoded.write(to: url, options: .atomic)
        } catch {
            logger.error("failed to save the prayer log: \(error.localizedDescription)")
        }
    }
}
