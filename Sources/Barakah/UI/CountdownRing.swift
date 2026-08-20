import SwiftUI

/// Progress through the current prayer's window, drawn as a ring.
///
/// It answers a question a list of times cannot: not "when is Asr" but "how much
/// of this window is left", which is the thing you actually glance for.
struct CountdownRing: View {
    var progress: Double
    var accent: Color
    var symbolName: String
    var size: CGFloat = 54

    var body: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.10))
            Circle()
                .stroke(accent.opacity(0.22), lineWidth: 4)

            Circle()
                .trim(from: 0, to: max(0.004, min(1, progress)))
                .stroke(
                    accent.gradient,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                // Start the arc at twelve o'clock rather than three.
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: progress)

            Image(systemName: symbolName)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(accent)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Progress through the current prayer window")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}
