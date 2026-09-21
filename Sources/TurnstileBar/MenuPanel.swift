import AppKit
import SwiftUI
import TurnstileCore

/// The whole menu: memory at the top, jobs in the middle, the app's own switches at the bottom.
struct MenuPanel: View {
    @ObservedObject var monitor: Monitor
    @State private var showAllRecent: Bool
    @State private var measuredList: CGFloat?

    init(monitor: Monitor, expandRecent: Bool = false) {
        self.monitor = monitor
        _showAllRecent = State(initialValue: expandRecent)
    }

    var body: some View {
        let health = monitor.health
        // "It starts with the next gated command" is false while nothing is gated.
        let showsIdle = monitor.snapshot == nil && !monitor.disabled && !health.contains(where: { $0.tone == .danger })
        VStack(alignment: .leading, spacing: 0) {
            if !health.isEmpty {
                HealthBanner(findings: health)
                Divider()
            }
            if let snapshot = monitor.snapshot {
                MemoryHeader(snapshot: snapshot)
                Divider()
                body(for: snapshot)
            } else if showsIdle {
                idle
            }
            if monitor.snapshot != nil || showsIdle {
                Divider()
            }
            gating
            if let message = monitor.message {
                Divider()
                banner(message)
            }
            Divider()
            footer
        }
        .frame(width: Panel.width)
    }

    @ViewBuilder
    private func body(for snapshot: StatusSnapshot) -> some View {
        let recent = MenuBarState.visibleRecent(snapshot.recent, expanded: showAllRecent)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if snapshot.running.isEmpty && snapshot.queued.isEmpty {
                    empty
                }
                // Ticks between polls, so elapsed times and countdowns don't freeze.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = context.date.timeIntervalSince1970
                    VStack(alignment: .leading, spacing: 0) {
                        jobs("Running", snapshot.running, now: now)
                        jobs("Queued", snapshot.queued, now: now)
                    }
                }
            }
            .padding(.bottom, 10)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { measuredList = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: Panel.listHeight(for: snapshot, recent: recent.count, measured: measuredList))
        // Outside the scroll view, so the last runs show on opening however long the queue is.
        if !snapshot.recent.isEmpty {
            recentSection(recent, total: snapshot.recent.count)
        }
    }

    @ViewBuilder
    private func jobs(_ title: String, _ jobs: [JobSnapshot], now: Double) -> some View {
        if !jobs.isEmpty {
            SectionHeader(title: title, count: jobs.count) {
                if jobs.contains(where: { MenuBarState.memoryFraction(for: $0) != nil }) {
                    Label("Memory vs. estimate", systemImage: "memorychip")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("Each bar is memory in use against what the job was expected to need. It isn't progress.")
                }
            }
            VStack(spacing: 2) {
                ForEach(jobs, id: \.id) { job in
                    JobRow(job: job, now: now, canPromote: MenuBarState.canPromote(job, in: jobs)) { monitor.send($0, to: job.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func recentSection(_ entries: [HistoryEntry], total: Int) -> some View {
        Divider()
        SectionHeader(title: "Recent", count: nil) {
            if total > MenuBarState.recentPreviewCount {
                Button(showAllRecent ? "Show less" : "Show \(total - MenuBarState.recentPreviewCount) more") {
                    withAnimation(.snappy(duration: 0.15)) { showAllRecent.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
            }
        }
        VStack(spacing: 0) {
            ForEach(entries, id: \.id) { entry in
                RecentRow(entry: entry)
            }
        }
        .padding(.bottom, 8)
    }

    private var empty: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Nothing running or queued")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Panel.gutter)
        .padding(.vertical, 14)
    }

    private var idle: some View {
        VStack(spacing: 5) {
            Image(systemName: MenuBarState.idleSymbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text("Nothing queued")
                .font(.system(size: 13, weight: .semibold))
            Text("The daemon starts with the next gated command")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    /// Machine-wide, so it sits below the jobs rather than on any one of them.
    private var gating: some View {
        let on = !monitor.disabled
        return HStack(spacing: 8) {
            Image(systemName: on ? "shield.fill" : MenuBarState.disabledSymbol)
                .font(.system(size: 12))
                .foregroundStyle(on ? MenuBarState.Tone.good.color : MenuBarState.Tone.danger.color)
                .frame(width: BadgeTile.defaultSize)
            VStack(alignment: .leading, spacing: 1) {
                Text("Gating")
                    .font(.system(size: 12, weight: .medium))
                Text(on ? "Heavy commands wait their turn" : "Off: every command runs ungated")
                    .font(.system(size: 11))
                    .foregroundStyle(on ? Color.secondary : MenuBarState.Tone.danger.color)
            }
            Spacer(minLength: 0)
            Toggle("Gating", isOn: Binding(get: { on }, set: { monitor.setGating($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(on ? "Let every command run ungated, on every shell, until you turn this back on" : "Gate heavy commands again")
        }
        .padding(.horizontal, Panel.gutter)
        .padding(.vertical, 8)
        .background(on ? Color.clear : MenuBarState.Tone.danger.color.opacity(0.08))
    }

    private var notificationsMenu: some View {
        Menu {
            ForEach(MenuBarState.Event.Kind.allCases, id: \.self) { kind in
                Toggle(kind.title, isOn: Binding(get: { monitor.notifying.contains(kind) }, set: { monitor.setNotifying(kind, $0) }))
            }
        } label: {
            Label("Notifications", systemImage: "bell")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Choose what Turnstile tells you about")
    }

    private func banner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.blue)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                monitor.clearMessage()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, Panel.gutter)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.08))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if monitor.canLaunchAtLogin {
                Toggle("Launch at login", isOn: Binding(get: { monitor.launchAtLogin }, set: { monitor.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
            Spacer(minLength: 0)
            if monitor.canNotify { notificationsMenu }
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 11))
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: 11))
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, Panel.gutter)
        .padding(.vertical, 8)
    }
}

/// A finished run on one line: outcome, what it was, how long, and how much memory at worst.
struct RecentRow: View {
    var entry: HistoryEntry

    var body: some View {
        let badge = MenuBarState.badge(for: entry)
        HStack(spacing: 8) {
            Image(systemName: badge.symbol)
                .font(.system(size: 12))
                .foregroundStyle(badge.tone.color)
                .frame(width: BadgeTile.defaultSize)
                .help(entry.outcome)
            HStack(spacing: 5) {
                Text(entry.project)
                    .font(.system(size: 12, weight: .medium))
                    .layoutPriority(1)
                Text(entry.key)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            .help("#\(entry.id) \(entry.project) \(entry.key)")
            if let note = MenuBarState.outcomeNote(for: entry) {
                Text(note)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(badge.tone == .neutral ? Color.secondary : badge.tone.color)
                    .fixedSize()
            }
            // A failure's output is the thing you came to read, so it gets a button rather than only a context menu.
            if let log = entry.log, entry.outcome != "ok" {
                Button { RunLogActions.open(log) } label: {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open #\(entry.id)'s output")
                .accessibilityLabel("Open log")
            }
            Spacer(minLength: 6)
            column(entry.duration.map(formatDuration) ?? "–", width: 52, help: "How long it ran")
            column(entry.peak.map { Bytes.format($0) } ?? "–", width: 52, help: "Peak memory")
        }
        .padding(.horizontal, Panel.gutter)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .contextMenu {
            if let log = entry.log {
                Button("Open log") { RunLogActions.open(log) }
            }
        }
    }

    private func column(_ text: String, width: CGFloat, help: String) -> some View {
        Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
            .help(help)
    }
}

/// Memory in use and who holds it, the numbers that decide what runs and what waits.
struct MemoryHeader: View {
    var snapshot: StatusSnapshot

    private var tone: MenuBarState.Tone { MenuBarState.memoryTone(snapshot.memoryLevel) }
    private var used: UInt64 { snapshot.physicalMemory - SystemMemory.free(level: snapshot.memoryLevel, of: snapshot.physicalMemory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Memory")
                    .font(.system(size: 13, weight: .semibold))
                // The tone is the only warning: amber when tight, red when jobs start pausing.
                Text("\(Bytes.format(used)) used of \(Bytes.format(snapshot.physicalMemory))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(tone == .good ? Color.secondary : tone.color)
                    .help("\(snapshot.memoryLevel)% free")
                Spacer(minLength: 0)
                if let version = snapshot.version {
                    Text(version)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            MemoryMeterView(meter: MemoryMeter(snapshot))
        }
        .padding(.horizontal, Panel.gutter)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

/// What's wrong with the install, and the command that fixes it.
struct HealthBanner: View {
    var findings: [Health.Finding]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(findings, id: \.text) { finding in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: Health.brokenSymbol)
                        .font(.system(size: 11))
                        .foregroundStyle(finding.tone.color)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(finding.text)
                            .font(.system(size: 11, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        if let fix = finding.fix {
                            fixButton(fix)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Panel.gutter)
        .padding(.vertical, 10)
        .background((findings.first?.tone.color ?? .clear).opacity(0.08))
    }

    private func fixButton(_ fix: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fix, forType: .string)
        } label: {
            HStack(spacing: 4) {
                Text(fix)
                    .font(.system(size: 10).monospaced())
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help("Copy to paste into a terminal")
    }
}
