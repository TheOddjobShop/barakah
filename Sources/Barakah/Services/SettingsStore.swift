import Foundation
import Observation
import OSLog

/// Owns the single `SettingsData` value, persists it, and lets SwiftUI observe it.
///
/// Writes are debounced: settings UI produces a storm of changes as sliders and
/// steppers move, and there is no reason to hit the disk for each one.
@MainActor
@Observable
public final class SettingsStore {
    public private(set) var data: SettingsData {
        didSet {
            guard data != oldValue else { return }
            scheduleSave()
            revision &+= 1
        }
    }

    /// Bumped on every accepted change, so dependents can re-derive cheaply
    /// without diffing the whole settings tree.
    public private(set) var revision: UInt64 = 0

    private var saveTask: Task<Void, Never>?
    private let url: URL
    private let log = Logger(subsystem: Barakah.subsystem, category: "settings")

    public init(url: URL = SettingsStore.defaultURL) {
        self.url = url
        self.data = SettingsStore.load(from: url, log: Logger(subsystem: Barakah.subsystem, category: "settings"))
    }

    /// Mutate settings in place. Everything funnels through here so persistence
    /// and change notification cannot be forgotten at a call site.
    public func update(_ mutate: (inout SettingsData) -> Void) {
        var copy = data
        mutate(&copy)
        data = copy
    }

    public func updateConfig(for kind: PrayerKind, _ mutate: (inout PrayerConfig) -> Void) {
        update { settings in
            var config = settings.config(for: kind)
            mutate(&config)
            settings.prayerConfigs[kind] = config
        }
    }

    public func resetToDefaults() {
        data = SettingsData()
        flush()
    }

    // MARK: - Persistence

    nonisolated public static var defaultURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Barakah", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    private static func load(from url: URL, log: Logger) -> SettingsData {
        guard let raw = try? Data(contentsOf: url) else { return SettingsData() }
        do {
            return try JSONDecoder().decode(SettingsData.self, from: raw)
        } catch {
            // A settings file we cannot read is preserved rather than clobbered —
            // it is the only copy of the user's configuration.
            log.error("settings unreadable, starting fresh: \(error.localizedDescription)")
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return SettingsData()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Write immediately. Called on debounce and on termination.
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = data
        let target = url
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(snapshot)
            try encoded.write(to: target, options: .atomic)
        } catch {
            log.error("failed to save settings: \(error.localizedDescription)")
        }
    }
}

/// App-wide constants that several subsystems need to agree on.
public enum Barakah {
    public static let subsystem = "dev.justin06lee.barakah"
    public static let bundleIdentifier = "dev.justin06lee.barakah"
    public static let displayName = "Barakah"
}
