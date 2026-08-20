import Foundation
import AppKit
import OSLog

/// Thin wrapper over the private `MediaRemote` framework — the same channel the
/// keyboard's play/pause key uses, which is why it reaches players no public API
/// can touch: Spotify, Music, VLC, IINA, and HTML5 video in Safari, Chrome and Arc.
///
/// Everything here is resolved at runtime with `dlsym` and every entry point is
/// optional. If Apple removes or gates a symbol, the corresponding capability
/// simply reports itself unavailable and `MediaController` falls through to the
/// next strategy — the app never crashes over it.
///
/// Note on reads vs. writes: since macOS 15.4 Apple gates *reading* now-playing
/// information behind an entitlement, so `nowPlayingInfo()` may legitimately
/// return nil on a current system even though `sendCommand` still works. Barakah
/// is built to tolerate exactly that — see `MediaController`.
final class MediaRemoteBridge {
    /// Command numbers understood by `MRMediaRemoteSendCommand`.
    enum Command: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
    }

    struct NowPlaying {
        var title: String?
        var artist: String?
        var album: String?
        /// Bundle identifier of the app that owns playback, when discoverable.
        var bundleIdentifier: String?
        var isPlaying: Bool

        var displayDescription: String? {
            if let title, let artist { return "\(title) — \(artist)" }
            return title ?? bundleIdentifier
        }
    }

    static let shared = MediaRemoteBridge()

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool
    private typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void

    private let handle: UnsafeMutableRawPointer?
    private let getInfo: GetInfoFn?
    private let sendCommandFn: SendCommandFn?
    private let getIsPlaying: GetIsPlayingFn?
    private let getPID: GetPIDFn?
    private let log = Logger(subsystem: Barakah.subsystem, category: "mediaremote")

    private init() {
        let library = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        )
        handle = library
        // Takes the handle as a parameter rather than reading the stored property,
        // so no stored property is touched before initialisation completes.
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let library, let pointer = dlsym(library, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        getInfo = sym("MRMediaRemoteGetNowPlayingInfo", as: GetInfoFn.self)
        sendCommandFn = sym("MRMediaRemoteSendCommand", as: SendCommandFn.self)
        getIsPlaying = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: GetIsPlayingFn.self)
        getPID = sym("MRMediaRemoteGetNowPlayingApplicationPID", as: GetPIDFn.self)

        if library == nil {
            log.notice("MediaRemote unavailable; falling back to scriptable players only")
        }
    }

    /// Whether commands can be sent at all.
    var canSendCommands: Bool { sendCommandFn != nil }

    /// Whether now-playing state can be read. False on systems where Apple has
    /// gated reads behind an entitlement.
    var canReadState: Bool { getIsPlaying != nil || getInfo != nil }

    /// Send a transport command to whatever currently owns Now Playing.
    ///
    /// Barakah only ever sends explicit `.pause` — never `.togglePlayPause` —
    /// so firing when nothing is playing is a guaranteed no-op rather than a
    /// surprise burst of music during the adhan.
    @discardableResult
    func send(_ command: Command) -> Bool {
        guard let sendCommandFn else { return false }
        let delivered = sendCommandFn(command.rawValue, nil)
        log.debug("sent \(String(describing: command)) -> \(delivered)")
        return delivered
    }

    /// Best-effort read of the current now-playing state.
    ///
    /// Returns nil when reads are unavailable — which is *not* the same as
    /// "nothing is playing", and callers must treat the two differently.
    func nowPlaying(timeout: Duration = .milliseconds(600)) async -> NowPlaying? {
        guard canReadState else { return nil }

        async let playing = withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            guard let getIsPlaying else { return continuation.resume(returning: nil) }
            let box = ResumeOnce(continuation)
            getIsPlaying(.global(qos: .userInitiated)) { value in box.resume(with: value) }
            Task { try? await Task.sleep(for: timeout); box.resume(with: nil) }
        }

        async let info = withCheckedContinuation { (continuation: CheckedContinuation<[String: Any]?, Never>) in
            guard let getInfo else { return continuation.resume(returning: nil) }
            let box = ResumeOnce(continuation)
            getInfo(.global(qos: .userInitiated)) { dictionary in box.resume(with: dictionary) }
            Task { try? await Task.sleep(for: timeout); box.resume(with: nil) }
        }

        async let pid = withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            guard let getPID else { return continuation.resume(returning: nil) }
            let box = ResumeOnce(continuation)
            getPID(.global(qos: .userInitiated)) { value in box.resume(with: value) }
            Task { try? await Task.sleep(for: timeout); box.resume(with: nil) }
        }

        let (isPlaying, dictionary, ownerPID) = await (playing, info, pid)

        // No signal at all means "cannot tell", which is a different answer from
        // "nothing is playing" and is reported as nil.
        guard isPlaying != nil || dictionary != nil else { return nil }

        let bundleID = ownerPID.flatMap { value -> String? in
            guard value > 0 else { return nil }
            return NSRunningApplication(processIdentifier: pid_t(value))?.bundleIdentifier
        }

        return NowPlaying(
            title: dictionary?["kMRMediaRemoteNowPlayingInfoTitle"] as? String,
            artist: dictionary?["kMRMediaRemoteNowPlayingInfoArtist"] as? String,
            album: dictionary?["kMRMediaRemoteNowPlayingInfoAlbum"] as? String,
            bundleIdentifier: bundleID,
            isPlaying: isPlaying ?? false
        )
    }
}

/// Guards a continuation against the double-resume that a racing callback and
/// timeout would otherwise cause.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let continuation: CheckedContinuation<T?, Never>
    private let lock = NSLock()
    private var done = false

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: T?) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(returning: value)
    }
}
