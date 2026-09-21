import SwiftUI
import TurnstileCore

/// One running or queued job: what it is, what it's using, and the controls for it.
struct JobRow: View {
    var job: JobSnapshot
    var now: Double
    /// False for the head of the queue, where moving to the front does nothing.
    var canPromote = true
    var send: (String) -> Void

    @State private var hoveringNow = false
    @Environment(\.previewHoveredJob) private var previewHoveredJob
    @State private var confirmingKill = false

    private var hovering: Bool { hoveringNow || previewHoveredJob == job.id }
    private var badge: MenuBarState.Badge { MenuBarState.badge(for: job) }
    private var actions: [MenuBarState.Action] { MenuBarState.actions(for: job) }
    private var queued: Bool { job.state == "queued" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BadgeTile(symbol: MenuBarState.symbol(for: job.resourceClass), tone: badge.tone)
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                Text(job.key)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.key)
                detail
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color(nsColor: .quaternaryLabelColor).opacity(0.5) : .clear)
        )
        .padding(.horizontal, Panel.gutter - 8)
        .onHover { inside in
            hoveringNow = inside
            if !inside { confirmingKill = false }
        }
        .contextMenu {
            Button("Open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: job.cwd)) }
        }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(job.project)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(job.cwd)
            if job.agent {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Started by an agent")
            }
            if job.joiners > 0 {
                Label("\(job.joiners)", systemImage: "person.2.fill")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("\(job.joiners) more \(job.joiners == 1 ? "caller is" : "callers are") sharing this run")
            }
            if let tag = MenuBarState.tag(for: job) {
                TagLabel(tag: tag)
            }
            Spacer(minLength: 6)
            trailing
        }
        .frame(height: Panel.actionSize)
    }

    /// Timing when idle, controls on hover, in one fixed-width slot so the text beside it never moves.
    private var trailing: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .trailing) {
                timing.opacity(hovering ? 0 : 1)
                secondaryActions.opacity(hovering ? 1 : 0)
            }
            .frame(width: Panel.actionsWidth, alignment: .trailing)
            promoteButton
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var timing: some View {
        HStack(spacing: 5) {
            Text("#\(job.id)")
                .foregroundStyle(.tertiary)
            Text(elapsed)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
        .help(queued ? "Waiting for \(elapsed)" : "Running for \(elapsed)")
    }

    /// Move to front is the one control a queued job always shows: it's the thing you came to do.
    @ViewBuilder
    private var promoteButton: some View {
        let bump = actions[0]
        let visible = canPromote && (queued || hovering)
        iconButton(bump, symbol: MenuBarState.symbol(for: bump), tint: queued ? .accentColor : Color(nsColor: .secondaryLabelColor)) {
            send(bump.message)
        }
        .background(queued && visible ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .opacity(visible ? 1 : 0)
        .disabled(!visible)
    }

    private var secondaryActions: some View {
        HStack(spacing: 2) {
            let toggle = actions[1]
            iconButton(toggle, symbol: MenuBarState.symbol(for: toggle), tint: Color(nsColor: .secondaryLabelColor)) {
                send(toggle.message)
            }
            Divider().frame(height: 12).padding(.horizontal, 3)
            killButton(actions[2])
        }
        .disabled(!hovering)
    }

    /// Killing a long build by a stray click is worse than one extra click.
    @ViewBuilder
    private func killButton(_ action: MenuBarState.Action) -> some View {
        if confirmingKill {
            Button("Sure?") {
                confirmingKill = false
                send(action.message)
            }
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .frame(height: Panel.actionSize)
            .help("Click again to \(action.title.lowercased()) #\(job.id)")
        } else {
            iconButton(action, symbol: MenuBarState.symbol(for: action), tint: .red) { confirmingKill = true }
        }
    }

    private func iconButton(_ action: MenuBarState.Action, symbol: String, tint: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: Panel.actionSize, height: Panel.actionSize)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(tint)
        .help("\(action.title): \(action.help)")
        .accessibilityLabel(action.title)
    }

    /// Memory for a running job; for a queued one, why it's waiting. #44 adds more here.
    @ViewBuilder
    private var detail: some View {
        if let fraction = MenuBarState.memoryFraction(for: job) {
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                MemoryBar(fraction: fraction, tone: MenuBarState.footprintTone(for: job))
                Text(MenuBarState.memoryText(for: job))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .help(MenuBarState.memoryHelp(for: job) ?? "")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "hourglass")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(MenuBarState.waitingHeadline(for: job, now: now) ?? "Waiting for its turn")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(MenuBarState.waitingText(for: job, now: now) ?? "")
                Spacer(minLength: 6)
                Text("~\(Bytes.format(job.estimate))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(MenuBarState.memoryText(for: job))
            }
        }
    }

    private var elapsed: String {
        let since = queued ? job.queuedAt : (job.startedAt ?? job.queuedAt)
        return formatDuration(max(0, now - since))
    }
}

extension EnvironmentValues {
    /// Draws one row as if hovered, for rendered fixtures.
    @Entry var previewHoveredJob: Int64?
}
