import SwiftUI
import TurnstileCore

/// One running or queued job: what it is, what it's using, and the controls for it.
struct JobRow: View {
    var job: JobSnapshot
    var now: Double
    var send: (String) -> Void

    @State private var hovering = false
    @State private var confirmingKill = false

    private var badge: MenuBarState.Badge { MenuBarState.badge(for: job) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BadgeTile(symbol: MenuBarState.symbol(for: job.resourceClass), tone: badge.tone)
            VStack(alignment: .leading, spacing: 3) {
                title
                meta
                if let fraction = MenuBarState.memoryFraction(for: job) {
                    HStack(spacing: 6) {
                        MemoryBar(fraction: fraction, tone: MenuBarState.footprintTone(for: job))
                        Text(Bytes.format(job.footprint ?? 0))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 1)
                } else if let waiting = job.waiting {
                    Text(waiting)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Panel.gutter)
        .padding(.vertical, 7)
        .background(hovering ? Color(nsColor: .quaternaryLabelColor).opacity(0.5) : .clear)
        .onHover { inside in
            hovering = inside
            if !inside { confirmingKill = false }
        }
    }

    private var title: some View {
        HStack(spacing: 5) {
            Text(job.project)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(job.key)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if job.agent {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Started by an agent")
            }
            Spacer(minLength: 4)
            if hovering { actions }
        }
    }

    private var meta: some View {
        HStack(spacing: 4) {
            Image(systemName: badge.symbol)
                .font(.system(size: 8))
                .foregroundStyle(badge.tone.color)
            Text("#\(job.id)")
                .monospacedDigit()
            Text("·")
            Text(MenuBarState.stateText(for: job))
            Text("·")
            Text(elapsed)
                .monospacedDigit()
            if job.joiners > 0 {
                Text("·")
                Text("+\(job.joiners) joined")
            }
            if MenuBarState.memoryFraction(for: job) == nil {
                Text("·")
                Text(MenuBarState.memoryText(for: job))
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var elapsed: String {
        let since = job.state == "queued" ? job.queuedAt : (job.startedAt ?? job.queuedAt)
        return formatDuration(max(0, now - since))
    }

    private var actions: some View {
        HStack(spacing: 2) {
            ForEach(MenuBarState.actions(for: job), id: \.message) { action in
                if action.message == "kill" {
                    killButton(action)
                } else {
                    button(action.title, MenuBarState.symbol(for: action), tone: .neutral) { send(action.message) }
                }
            }
        }
    }

    /// Killing a long build by a stray click is worse than one extra click.
    private func killButton(_ action: MenuBarState.Action) -> some View {
        Group {
            if confirmingKill {
                Button("Sure?") {
                    confirmingKill = false
                    send(action.message)
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            } else {
                button(action.title, MenuBarState.symbol(for: action), tone: .danger) { confirmingKill = true }
            }
        }
    }

    private func button(_ title: String, _ symbol: String, tone: MenuBarState.Tone, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 16)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tone == .danger ? Color.red : Color(nsColor: .secondaryLabelColor))
        .help(title)
    }
}
