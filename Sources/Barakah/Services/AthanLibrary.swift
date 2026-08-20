import Foundation

/// Finds athan recordings available to play.
///
/// Two sources, in priority order: files the user has installed into
/// Application Support, then anything bundled with the app.
///
/// The Application Support directory is the important one. Barakah deliberately
/// ships no adhan recording — see `assets/NOTICE.md` for why — so `make adhan`
/// drops a freely-licensed file here and it appears in the picker immediately,
/// with no rebuild and nothing copyrighted in the repository.
public enum AthanLibrary {
    public static let supportedExtensions = ["m4a", "mp3", "caf", "wav", "aiff", "aif", "ogg"]

    /// `~/Library/Application Support/Barakah/Athan`, created on demand.
    public static var installedDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base
            .appendingPathComponent("Barakah", isDirectory: true)
            .appendingPathComponent("Athan", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Every installed or bundled recording, by resource name, sorted for a
    /// stable picker order.
    public static func available() -> [String] {
        var names = Set<String>()
        for url in installedURLs() { names.insert(url.deletingPathExtension().lastPathComponent) }
        for url in bundledURLs() { names.insert(url.deletingPathExtension().lastPathComponent) }
        return names.sorted()
    }

    /// Resolve a resource name to a playable file, preferring the user's own
    /// copy so a downloaded file overrides a bundled one of the same name.
    public static func url(forResource name: String) -> URL? {
        installedURLs().first { $0.deletingPathExtension().lastPathComponent == name }
            ?? bundledURLs().first { $0.deletingPathExtension().lastPathComponent == name }
    }

    private static func installedURLs() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: installedDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
    }

    private static func bundledURLs() -> [URL] {
        var urls: [URL] = []
        for ext in supportedExtensions {
            urls += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Athan") ?? []
        }
        return urls
    }
}
