import AVFoundation
import Foundation
import OSLog

/// Works out how much to turn a recording up — or down — so every athan lands at
/// roughly the same loudness.
///
/// This exists because adhan recordings in the wild are mastered nowhere near
/// each other. Measured examples: a Wikimedia field recording at −26.8 LUFS, a
/// broadcast-mastered upload at −8.8 LUFS. That is an eighteen-decibel spread —
/// the same volume slider produces an inaudible whisper for one and a shock for
/// the other. Without correction the slider is meaningless and the first thing a
/// new user does is get startled or miss the prayer.
///
/// The measurement is a loudness approximation, not true EBU R128: an
/// energy-weighted mean over the passages that actually contain sound, which
/// tracks R128's integrated loudness closely enough for setting a playback gain
/// and costs one pass over the file with no external tools.
enum AudioNormalizer {
    /// Target playback loudness, in dBFS. Chosen to sit close to the −16 LUFS
    /// that streaming platforms normalise to, so an athan is about as loud as
    /// whatever the user was listening to before it interrupted.
    private static let targetDB: Float = -16

    /// Never amplify beyond this. A very quiet recording is usually quiet
    /// because it is a distant field recording with a high noise floor, and
    /// pushing it 20 dB would mostly amplify hiss.
    private static let maxGain: Float = 6.0
    private static let minGain: Float = 0.05

    private static let log = Logger(subsystem: Barakah.subsystem, category: "normalise")
    private static let cache = Cache()

    /// A multiplier to apply to the player's volume for this file.
    ///
    /// Cached in memory: measuring costs one read of the file, and the answer
    /// cannot change unless the file does.
    static func gain(for url: URL) -> Float {
        if let cached = cache.value(for: url) { return cached }
        let measured = measure(url) ?? 1.0
        cache.set(measured, for: url)
        return measured
    }

    private static func measure(_ url: URL) -> Float? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let total = file.length
        guard total > 0 else { return nil }

        let frameCapacity: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }

        // Blocks quieter than this are treated as silence and left out of the
        // mean. Averaging the gaps between phrases in — and the adhan has long
        // ones — would drag the measurement down and overcorrect.
        let silenceFloor: Float = 0.0005

        var energy = 0.0
        var counted = 0

        while file.framePosition < total {
            buffer.frameLength = 0
            guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else { break }
            guard let channels = buffer.floatChannelData else { break }

            let frames = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)

            for frame in stride(from: 0, to: frames, by: 4) {   // every 4th frame is plenty
                var sum: Float = 0
                for channel in 0..<channelCount {
                    let sample = channels[channel][frame]
                    sum += sample * sample
                }
                let mean = sum / Float(channelCount)
                if mean > silenceFloor * silenceFloor {
                    energy += Double(mean)
                    counted += 1
                }
            }
        }

        guard counted > 0 else { return nil }

        let rms = Float(sqrt(energy / Double(counted)))
        guard rms > 0 else { return nil }

        let currentDB = 20 * log10(rms)
        let gain = pow(10, (targetDB - currentDB) / 20)
        let clamped = min(maxGain, max(minGain, gain))

        log.debug("\(url.lastPathComponent, privacy: .public): \(currentDB) dBFS -> gain \(clamped)")
        return clamped
    }

    /// Thread-safe memo. Keyed by path and modification date so replacing a file
    /// with a different recording of the same name re-measures.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Float] = [:]

        private func key(for url: URL) -> String {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            return "\(url.path)#\(modified)"
        }

        func value(for url: URL) -> Float? {
            lock.lock(); defer { lock.unlock() }
            return storage[key(for: url)]
        }

        func set(_ value: Float, for url: URL) {
            lock.lock(); defer { lock.unlock() }
            storage[key(for: url)] = value
        }
    }
}
