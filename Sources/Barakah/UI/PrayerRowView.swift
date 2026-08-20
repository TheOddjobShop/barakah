import SwiftUI

/// One line of the day: name, athan time, iqama time.
///
/// The next prayer is filled with its accent rather than merely bolded, so the
/// panel can be read at a glance from across a desk. Prayers already past are
/// dimmed — the eye should land on what is next, not scan six equal rows.
struct PrayerRowView: View {
    let prayer: ScheduledPrayer
    let formatter: PrayerFormatter
    let state: RowState
    let isMuted: Bool
    var onToggleMute: () -> Void

    enum RowState {
        case past, current, next, upcoming
    }

    @State private var isHovering = false

    private var accent: Color { Theme.accent(for: prayer.kind) }

    private var isHighlighted: Bool { state == .next }

    private var opacity: Double {
        switch state {
        case .past: 0.42
        case .current: 0.85
        case .next, .upcoming: 1.0
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: prayer.kind.symbolName)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isHighlighted ? accent : .secondary)
                .frame(width: 18)

            Text(prayer.kind.name)
                .font(.system(size: 13, weight: isHighlighted ? .semibold : .regular))
                .foregroundStyle(isHighlighted ? .primary : .primary)

            if isMuted {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Athan silenced for today")
            }

            Spacer(minLength: 8)

            // Athan first, then iqama — the same order every masjid timetable
            // prints them in. Reversing the two reads as though the iqama came
            // first, which is exactly the confusion this app exists to remove.
            Text(formatter.time(prayer.athan))
                .font(Theme.timeFont)
                .fontWeight(isHighlighted ? .semibold : .regular)
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .frame(width: Theme.timeColumnWidth, alignment: .trailing)

            Text(prayer.iqama.map(formatter.time) ?? "—")
                .font(Theme.timeFont)
                .foregroundStyle(prayer.iqama == nil ? .quaternary : .tertiary)
                .frame(width: Theme.timeColumnWidth, alignment: .trailing)

            // The mute affordance only appears on hover, so the resting state
            // stays quiet.
            Button(action: onToggleMute) {
                Image(systemName: isMuted ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering && prayer.kind.isPrayer ? 1 : 0)
            .frame(width: 14)
            .help(isMuted ? "Unsilence \(prayer.kind.name) today" : "Silence \(prayer.kind.name) today")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: Theme.cornerRadius - 2, style: .continuous)
                .fill(isHighlighted ? accent.opacity(0.14) : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius - 2, style: .continuous)
                        .strokeBorder(accent.opacity(isHighlighted ? 0.28 : 0), lineWidth: 1)
                }
        }
        .opacity(opacity)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = ["\(prayer.kind.name) at \(formatter.time(prayer.athan))"]
        if let iqama = prayer.iqama { parts.append("iqama at \(formatter.time(iqama))") }
        if isMuted { parts.append("silenced today") }
        if state == .next { parts.append("next prayer") }
        return parts.joined(separator: ", ")
    }
}
