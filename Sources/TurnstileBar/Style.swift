import SwiftUI
import TurnstileCore

extension MenuBarState.Tone {
    var color: Color {
        switch self {
        case .good: return .green
        case .warning: return .orange
        case .danger: return .red
        case .neutral: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

/// The panel's one fixed dimension. Everything else sizes to content.
enum Panel {
    static let width: CGFloat = 320
    static let gutter: CGFloat = 12
    /// Past this the job list scrolls rather than growing down the screen.
    static let listHeight: CGFloat = 320
    private static let sectionHeight: CGFloat = 31
    private static let jobHeight: CGFloat = 62
    private static let emptyHeight: CGFloat = 56
    private static let recentHeaderHeight: CGFloat = 39

    /// ScrollView has no useful ideal height inside a MenuBarExtra window. Size it from the
    /// visible rows, then cap it before the panel crowds out the screen.
    static func listHeight(for snapshot: StatusSnapshot, showingRecent: Bool) -> CGFloat {
        let jobs = snapshot.running.count + snapshot.queued.count
        let sections = (snapshot.running.isEmpty ? 0 : 1) + (snapshot.queued.isEmpty ? 0 : 1)
        var height = jobs == 0 ? emptyHeight : CGFloat(sections) * sectionHeight + CGFloat(jobs) * jobHeight
        if !snapshot.recent.isEmpty { height += recentHeaderHeight }
        if showingRecent { height += CGFloat(snapshot.recent.count) * jobHeight }
        return min(listHeight, height + 8)
    }
}

/// A small uppercase heading with the number of things under it.
struct SectionHeader: View {
    var title: String
    var count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Panel.gutter)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// A symbol in a tinted rounded square, the same shape wherever a row starts.
struct BadgeTile: View {
    var symbol: String
    var tone: MenuBarState.Tone
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size / 3.5, style: .continuous)
            .fill(tone.color.opacity(0.15))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(tone.color)
            }
    }
}

/// A thin capacity bar. `fraction` is clamped by the caller.
struct MemoryBar: View {
    var fraction: Double
    var tone: MenuBarState.Tone
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                Capsule()
                    .fill(tone.color.gradient)
                    .frame(width: max(2, geometry.size.width * fraction))
            }
        }
        .frame(height: height)
    }
}
