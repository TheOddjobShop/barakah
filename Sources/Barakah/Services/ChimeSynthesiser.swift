import Foundation
import AVFoundation
import OSLog

/// Renders Barakah's built-in chime to a WAV file on first use.
///
/// Synthesising rather than shipping a recording means the default sound has no
/// licensing question attached to it at all — which matters for a project people
/// are meant to be able to fork, redistribute and package freely.
///
/// The tone is a struck bell: a set of slightly inharmonic partials with
/// independent exponential decays, struck three times. Inharmonicity is what
/// makes it read as a bell rather than an alarm clock.
enum ChimeSynthesiser {
    private static let sampleRate = 44_100.0
    private static let log = Logger(subsystem: Barakah.subsystem, category: "chime")

    /// Partial frequency ratios and their relative amplitudes, loosely following
    /// the spectrum of a small struck bell.
    private static let partials: [(ratio: Double, amplitude: Double, decay: Double)] = [
        (1.000, 0.55, 1.9),
        (2.008, 0.30, 1.5),
        (2.414, 0.18, 1.2),
        (3.011, 0.12, 0.9),
        (4.166, 0.07, 0.7),
        (5.433, 0.04, 0.5),
    ]

    private static let fundamental = 587.33  // D5 — bright without being shrill
    private static let strikes = 3
    private static let strikeInterval = 1.7
    private static let tail = 2.6

    /// Path to the rendered chime, generating it if absent.
    static func url() throws -> URL {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = caches.appendingPathComponent("Barakah", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Version the filename so a change to the synthesis parameters supersedes
        // any previously cached render.
        let target = directory.appendingPathComponent("chime-v1.wav")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try render(to: target)
        log.debug("rendered chime to \(target.path, privacy: .public)")
        return target
    }

    private static func render(to url: URL) throws {
        let duration = Double(strikes - 1) * strikeInterval + tail
        let frameCount = Int(duration * sampleRate)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channels = buffer.floatChannelData else { throw CocoaError(.fileWriteUnknown) }

        for frame in 0..<frameCount {
            let t = Double(frame) / sampleRate
            var sample = 0.0

            for strike in 0..<strikes {
                let onset = Double(strike) * strikeInterval
                guard t >= onset else { continue }
                let age = t - onset
                // Later strikes are softer, the way a hand-struck bell decays.
                let strikeGain = pow(0.78, Double(strike))

                for partial in partials {
                    let envelope = exp(-age / partial.decay)
                    // A short attack ramp removes the click of an instant onset.
                    let attack = min(1.0, age / 0.004)
                    sample += sin(2 * .pi * fundamental * partial.ratio * age)
                        * partial.amplitude * envelope * attack * strikeGain
                }
            }

            // Gentle saturation keeps the strike transients from clipping hard.
            let value = Float(tanh(sample * 0.8) * 0.72)
            channels[0][frame] = value
            channels[1][frame] = value
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        )
        try file.write(from: buffer)
    }
}
