import SwiftUI
import TurnstileCore

/// Where memory is going, and whether the next queued job fits: a stacked bar with the reserve marked and the head of the queue as a ghost.
struct MemoryMeterView: View {
    var meter: MemoryMeter

    static let barHeight: CGFloat = 12
    /// Ordered so that neighbouring hues, which collisions fall through to, still read as different.
    private static let palette: [Color] = [.blue, .pink, .teal, .purple, .brown, .indigo]

    static func color(hue: Int) -> Color { palette[hue % palette.count] }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            bar
            legend
            if let verdict = Self.verdict(meter) {
                Text(verdict)
                    .font(.system(size: 10))
                    .foregroundStyle(meter.blocker == nil ? Color.secondary : MenuBarState.Tone.warning.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: meter)
    }

    private var bar: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / CGFloat(max(1, meter.span))
            let x = { (bytes: UInt64) in CGFloat(bytes) * scale }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .quaternaryLabelColor))
                HStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.45))
                        .frame(width: x(meter.other))
                        .help("Other apps and the system: \(Bytes.format(meter.other))")
                    ForEach(meter.segments, id: \.id) { segment in
                        let color = Self.color(hue: segment.hue)
                        HStack(spacing: 0) {
                            Rectangle().fill(color.opacity(segment.paused ? 0.5 : 1)).frame(width: x(segment.used))
                            Rectangle().fill(color.opacity(0.3)).frame(width: x(segment.committed))
                        }
                        .help(Self.help(for: segment))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                if let ghost = meter.ghost {
                    let tone: MenuBarState.Tone = ghost.fits ? .good : .warning
                    let start = x(meter.committedEnd)
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(tone.color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .background(RoundedRectangle(cornerRadius: 3).fill(tone.color.opacity(0.12)))
                        .frame(width: max(4, min(x(ghost.estimate), geometry.size.width - start)))
                        .offset(x: start)
                        .help(Self.help(for: ghost, spare: meter.spare))
                }
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: Self.barHeight + 6)
                    .offset(x: x(meter.reserveAt) - 1)
                    .help("Reserve: \(Bytes.format(meter.reserve)) kept free. New jobs must fit left of this line.")
            }
        }
        .frame(height: Self.barHeight)
        .padding(.vertical, 3)
    }

    /// What each part of the bar is, readable without hovering. Jobs are named in their rows, which carry the same dot.
    private var legend: some View {
        HStack(spacing: 10) {
            key(Circle().fill(Color.secondary.opacity(0.45)), "Other", Bytes.format(meter.other))
                .help("Other apps and the system: \(Bytes.format(meter.other))")
            if !meter.segments.isEmpty {
                key(jobsSwatch, jobsName, Bytes.format(meter.segments.reduce(0) { $0 + $1.used }))
                    .help(meter.segments.map { Self.help(for: $0) }.joined(separator: "\n"))
            }
            if let ghost = meter.ghost {
                key(ghostSwatch(ghost), "Next", "~\(Bytes.format(ghost.estimate))")
                    .help(Self.help(for: ghost, spare: meter.spare))
            }
            Spacer(minLength: 0)
            Text("\(Bytes.format(meter.spare)) spare")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("Free memory, less the reserve and what running jobs are still expected to claim. What a new job can have.")
        }
        .font(.system(size: 10))
    }

    private var jobsName: String {
        meter.segments.count == 1 ? meter.segments[0].project : "\(meter.segments.count) jobs"
    }

    /// One slice per running job, in the colours the bar uses.
    private var jobsSwatch: some View {
        HStack(spacing: 0) {
            ForEach(meter.segments, id: \.id) { Rectangle().fill(Self.color(hue: $0.hue)) }
        }
        .clipShape(Circle())
    }

    private func ghostSwatch(_ ghost: MemoryMeter.Ghost) -> some View {
        let color = (ghost.fits ? MenuBarState.Tone.good : .warning).color
        return RoundedRectangle(cornerRadius: 2)
            .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [2, 1]))
            .background(RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.12)))
    }

    private func key(_ swatch: some View, _ name: String, _ amount: String) -> some View {
        HStack(spacing: 4) {
            swatch.frame(width: 7, height: 7)
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(amount)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    /// Why the head of the queue waits.
    static func verdict(_ meter: MemoryMeter) -> String? {
        guard let ghost = meter.ghost else { return nil }
        switch meter.blocker {
        case .paused: return "Next waits for the paused job to resume"
        case .memory: return "Next needs ~\(Bytes.format(ghost.estimate)), only \(Bytes.format(meter.spare)) spare"
        case let .slot(cls): return "Next waits for a \(cls.rawValue) slot, not memory"
        case nil: return "Next fits"
        }
    }

    static func help(for ghost: MemoryMeter.Ghost, spare: UInt64) -> String {
        "Next in the queue: #\(ghost.id) \(ghost.label), needs ~\(Bytes.format(ghost.estimate)). "
            + (ghost.fits ? "It fits." : "It doesn't fit in the \(Bytes.format(spare)) spare.")
    }

    static func help(for segment: MemoryMeter.Segment) -> String {
        let more = segment.committed > 0 ? ", ~\(Bytes.format(segment.committed)) more expected" : ""
        return "#\(segment.id) \(segment.label): \(Bytes.format(segment.used)) in use\(more)\(segment.paused ? ", paused" : "")"
    }
}

/// Slots in use per class, the other thing besides memory that decides what runs.
struct SlotChips: View {
    var meter: MemoryMeter
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    var body: some View {
        HStack(spacing: 6) {
            ForEach(meter.slots, id: \.resourceClass) { slot in
                let blocking = meter.blocker == .slot(slot.resourceClass)
                HStack(spacing: 3) {
                    Image(systemName: MenuBarState.symbol(for: slot.resourceClass))
                    Text("\(slot.running)/\(slot.limit)").monospacedDigit()
                }
                .foregroundStyle(blocking ? MenuBarState.Tone.warning.color : Color.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(blocking ? MenuBarState.Tone.warning.color.opacity(0.14) : Color(nsColor: .quaternaryLabelColor), in: Capsule())
                .fixedSize()
                .hoverTip(Self.help(for: slot, blocking: blocking))
            }
        }
        .font(.system(size: 10))
        .contentShape(.rect)
        .pointerStyle(.link)
        .onTapGesture {
            settingsTab = .limits
            NSApplication.shared.activate()
            openSettings()
        }
    }

    static func help(for slot: MemoryMeter.Slot, blocking: Bool) -> String {
        let name = slot.resourceClass.rawValue
        let limit = slot.limit == 1 ? "1 \(name) job runs" : "\(slot.limit) \(name) jobs run"
        let queued = slot.queued > 0 ? ", \(slot.queued) waiting" : ""
        let waiting = blocking ? " The next job is waiting on this, not memory." : ""
        return "\(name.capitalized) slots: \(slot.running) of \(slot.limit) in use\(queued). At most \(limit) at once, however much memory is spare.\(waiting) Click to change."
    }
}
