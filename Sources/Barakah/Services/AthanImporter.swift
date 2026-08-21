import Foundation
import AVFoundation
import OSLog

/// Copies a recording the user picked into Barakah's own Athan folder.
///
/// Importing rather than merely referencing matters for a menu bar app that has
/// to work unattended at Fajr. A file left in Downloads gets tidied away, moved,
/// or lands on an external disk that is not mounted at 5am — and the athan then
/// silently falls back to the chime. A copy under Application Support is always
/// there, and it survives the app being reinstalled.
enum AthanImporter {
    enum ImportError: LocalizedError {
        case unreadable
        case noAudio

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file could not be opened."
            case .noAudio: "That file does not contain any audio Barakah can play."
            }
        }
    }

    private static let log = Logger(subsystem: Barakah.subsystem, category: "import")

    /// Import `url`, returning the resource name to store in settings.
    @discardableResult
    static func `import`(_ url: URL) throws -> String {
        // A file picked through the open panel is security-scoped; a file
        // dragged onto the window generally is not. Asking either way is
        // harmless and covers both.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Refuse anything that will not actually play, so the failure surfaces
        // now rather than as silence at Maghrib.
        guard (try? AVAudioFile(forReading: url)) != nil else {
            throw (FileManager.default.isReadableFile(atPath: url.path)
                   ? ImportError.noAudio
                   : ImportError.unreadable)
        }

        let name = uniqueName(for: url)
        let destination = AthanLibrary.installedDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(url.pathExtension)

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        log.info("imported athan \(name, privacy: .public)")
        return name
    }

    /// Keep the user's own filename, but avoid silently replacing a different
    /// recording that happens to share it.
    private static func uniqueName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let existing = Set(AthanLibrary.available())
        guard existing.contains(base) else { return base }

        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    /// Remove an installed recording.
    static func remove(_ name: String) {
        guard let url = AthanLibrary.url(forResource: name),
              url.path.hasPrefix(AthanLibrary.installedDirectory.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
