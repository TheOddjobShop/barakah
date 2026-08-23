import Foundation
import MachO

/// Finds athan recordings available to play.
///
/// Two sources, in priority order: files the user has installed into
/// Application Support, then recordings shipped with Barakah. The default
/// recording lives in a Mach-O section so it travels with even a standalone
/// copy of the executable; AVAudioPlayer receives a cached extracted copy.
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
        var urls = EmbeddedAthan.url.map { [$0] } ?? []
        for ext in supportedExtensions {
            urls += Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Athan") ?? []
        }
        return urls
    }
}

/// Materialises the default recording embedded by Package.swift's linker flags.
///
/// Audio APIs want a file URL rather than an address inside the executable. The
/// cache is compared before writing, so normal launches do no disk work and an
/// app update that changes the recording replaces the stale copy automatically.
private enum EmbeddedAthan {
    static let url: URL? = {
        guard let data = data else { return nil }

        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base
            .appendingPathComponent("Barakah", isDirectory: true)
            .appendingPathComponent("Embedded", isDirectory: true)
        let destination = directory.appendingPathComponent(
            "\(AthanSound.defaultBundledName).m4a"
        )

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? Data(contentsOf: destination, options: .mappedIfSafe)) != data {
                try data.write(to: destination, options: .atomic)
            }
            return destination
        } catch {
            return nil
        }
    }()

    private static var data: Data? {
        // In the app this is image zero. Under `swift test`, Barakah is loaded
        // into the XCTest host, so search all loaded images to exercise the same
        // extraction code there as well.
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), header.pointee.magic == MH_MAGIC_64 else {
                continue
            }
            let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
            var size: UInt = 0
            if let bytes = getsectiondata(header64, "__DATA", "__adhan", &size), size > 0 {
                return Data(bytes: bytes, count: Int(size))
            }
        }
        return nil
    }
}
