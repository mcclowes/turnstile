import AppKit
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
    static let width: CGFloat = 390
    static let gutter: CGFloat = 16
    /// Room for a row's trailing controls, held whether or not they're showing so nothing shifts on hover.
    static let actionsWidth: CGFloat = 76
    static let actionSize: CGFloat = 22
    /// Past this the job list scrolls rather than growing down the screen.
    static let maxListHeight: CGFloat = 480
    /// What the header, banners, and footer need around the list.
    private static let chromeHeight: CGFloat = 220
    private static let sectionHeight: CGFloat = 36
    private static let runningHeight: CGFloat = 70
    private static let queuedHeight: CGFloat = 70
    private static let emptyHeight: CGFloat = 56
    private static let recentHeaderHeight: CGFloat = 45
    private static let recentRowHeight: CGFloat = 28

    /// The cap, shrunk on short screens so the panel, recent runs included, never runs off the bottom.
    static func listCap(recent: Int) -> CGFloat {
        let room = maxListHeight
        guard let screen = NSScreen.main?.visibleFrame.height else { return room }
        return max(160, min(room, screen - chromeHeight - recentHeight(recent)))
    }

    /// ScrollView has no useful ideal height inside a MenuBarExtra window. Estimate it from the
    /// visible rows until the content has been measured, then cap it.
    static func listHeight(for snapshot: StatusSnapshot, recent: Int, measured: CGFloat?) -> CGFloat {
        min(listCap(recent: recent), measured ?? estimate(snapshot))
    }

    private static func recentHeight(_ count: Int) -> CGFloat {
        count == 0 ? 0 : recentHeaderHeight + CGFloat(count) * recentRowHeight
    }

    private static func estimate(_ snapshot: StatusSnapshot) -> CGFloat {
        let sections = (snapshot.running.isEmpty ? 0 : 1) + (snapshot.queued.isEmpty ? 0 : 1)
        let empty = snapshot.running.isEmpty && snapshot.queued.isEmpty
        var height = empty ? emptyHeight : CGFloat(sections) * sectionHeight
        height += CGFloat(snapshot.running.count) * runningHeight + CGFloat(snapshot.queued.count) * queuedHeight
        return height + 10
    }
}

/// A small uppercase heading with the number of things under it, and optionally what its rows measure.
struct SectionHeader<Accessory: View>: View {
    var title: String
    var count: Int?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
            }
            Spacer(minLength: 0)
            accessory
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Panel.gutter)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, count: Int?) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// A symbol in a tinted rounded square, the same shape wherever a row starts.
struct BadgeTile: View {
    var symbol: String
    static let defaultSize: CGFloat = 28

    var tone: MenuBarState.Tone
    var size: CGFloat = defaultSize

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

/// A small capsule for a state the section heading doesn't already give.
struct TagLabel: View {
    var tag: MenuBarState.Tag

    var body: some View {
        Text(tag.text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tag.tone == .neutral ? Color.secondary : tag.tone.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background((tag.tone == .neutral ? Color(nsColor: .quaternaryLabelColor) : tag.tone.color.opacity(0.14)), in: Capsule())
            .fixedSize()
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
