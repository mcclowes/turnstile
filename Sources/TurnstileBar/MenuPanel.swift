import AppKit
import SwiftUI
import TurnstileCore

/// The whole menu: memory at the top, jobs in the middle, Settings and Quit at the bottom.
struct MenuPanel: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.openSettings) private var openSettings
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
            if monitor.disabled {
                gatingOff
                Divider()
            }
            if let snapshot = monitor.snapshot {
                MemoryHeader(snapshot: snapshot)
                    .zIndex(1)
                Divider()
                body(for: snapshot)
                Divider()
            } else if showsIdle {
                idle
                Divider()
            }
            if let message = monitor.message {
                banner(message)
                Divider()
            }
            footer
        }
        .frame(width: Panel.width)
    }

    @ViewBuilder
    private func body(for snapshot: StatusSnapshot) -> some View {
        let recent = MenuBarState.visibleRecent(snapshot.recent, expanded: showAllRecent)
        let isEmpty = snapshot.running.isEmpty && snapshot.queued.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isEmpty {
                    empty
                }
                // Ticks between polls, so elapsed times and countdowns don't freeze.
                let hues = Dictionary(uniqueKeysWithValues: MemoryMeter(snapshot).segments.map { ($0.id, $0.hue) })
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = context.date.timeIntervalSince1970
                    VStack(alignment: .leading, spacing: 0) {
                        jobs("Running", snapshot.running, now: now, hues: hues)
                        jobs("Queued", snapshot.queued, now: now, hues: hues)
                    }
                }
            }
            .padding(.bottom, isEmpty ? 0 : 10)
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
    private func jobs(_ title: String, _ jobs: [JobSnapshot], now: Double, hues: [Int64: Int]) -> some View {
        if !jobs.isEmpty {
            SectionHeader(title: title, count: jobs.count)
            VStack(spacing: 2) {
                ForEach(jobs, id: \.id) { job in
                    JobRow(job: job, now: now, hue: hues[job.id], canPromote: MenuBarState.canPromote(job, in: jobs)) { monitor.send($0, to: job.id) }
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
            Image(systemName: MenuBarState.emptySymbol)
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

    /// Louder than the footer's mode picker, because nothing is protected until it's back on.
    private var gatingOff: some View {
        HStack(spacing: 8) {
            Image(systemName: MenuBarState.disabledSymbol)
                .font(.system(size: 12))
                .foregroundStyle(MenuBarState.Tone.danger.color)
                .frame(width: BadgeTile.defaultSize)
            Text("Gating is off: every command runs ungated")
                .font(.system(size: 11))
                .foregroundStyle(MenuBarState.Tone.danger.color)
            Spacer(minLength: 0)
            Button("Turn on") { monitor.setMode(.gated) }
                .controlSize(.small)
                .help("Gate heavy commands again")
        }
        .padding(.horizontal, Panel.gutter)
        .padding(.vertical, 8)
        .background(MenuBarState.Tone.danger.color.opacity(0.08))
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
            modePicker
            Spacer(minLength: 0)
            Button {
                // An accessory app isn't active, so SettingsLink alone opens nothing visible.
                NSApplication.shared.activate()
                openSettings()
            } label: {
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

    /// A single running job is paused from its own row, not here.
    private var modePicker: some View {
        let mode = monitor.mode
        let tint: Color = switch mode {
        case .gated: .secondary
        case .paused: MenuBarState.Tone.warning.color
        case .ungated: MenuBarState.Tone.danger.color
        }
        return Menu {
            Picker("Mode", selection: Binding(get: { monitor.mode }, set: { monitor.setMode($0) })) {
                ForEach(GatingMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(mode.title, systemImage: mode.symbol)
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(tint)
        .tint(tint)
        .help(mode.detail)
    }
}

/// A finished run on one line: outcome, what it was, how long, and how much memory at worst.
struct RecentRow: View {
    var entry: HistoryEntry
    @State private var hoveringBadge = false

    var body: some View {
        HStack(spacing: 8) {
            outcome
            HStack(spacing: 5) {
                Text(entry.project)
                    .font(.system(size: 12, weight: .medium))
                    .layoutPriority(1)
                    .help("#\(entry.id) \(entry.project)")
                Text(entry.key)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .help(entry.key)
            }
            .lineLimit(1)
            if let note = MenuBarState.outcomeNote(for: entry) {
                let tone = MenuBarState.badge(for: entry).tone
                Text(note)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
                    .fixedSize()
            }
            Spacer(minLength: 6)
            stats
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

    /// Says what happened on hover; with a log, it turns into the button that opens it.
    @ViewBuilder
    private var outcome: some View {
        let badge = MenuBarState.badge(for: entry)
        let icon = Image(systemName: hoveringBadge && entry.log != nil ? "doc.text" : badge.symbol)
            .font(.system(size: 12))
            .foregroundStyle(badge.tone.color)
            .frame(width: BadgeTile.defaultSize)
            .contentShape(.rect)
        Group {
            if let log = entry.log {
                Button { RunLogActions.open(log) } label: { icon }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open log")
            } else {
                icon
            }
        }
        .onHover { hoveringBadge = $0 }
        .help(MenuBarState.outcomeHelp(for: entry))
    }

    /// "1.9 GB · 7m25s", matching the running rows so the two sections line up.
    private var stats: some View {
        let peak = entry.peak.map { Bytes.format($0) }
        let duration = entry.duration.map(formatDuration)
        return Text([peak, duration].compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .help([peak.map { "Peak memory \($0)" }, duration.map { "Ran for \($0)" }]
                .compactMap { $0 }.joined(separator: " · "))
    }
}

/// Memory in use and who holds it, the numbers that decide what runs and what waits.
struct MemoryHeader: View {
    var snapshot: StatusSnapshot

    private var tone: MenuBarState.Tone { MenuBarState.memoryTone(snapshot.memoryLevel) }
    private var used: UInt64 { snapshot.physicalMemory - SystemMemory.free(level: snapshot.memoryLevel, of: snapshot.physicalMemory) }

    var body: some View {
        let meter = MemoryMeter(snapshot)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Memory")
                    .font(.system(size: 13, weight: .semibold))
                // The tone is the only warning: amber when tight, red when jobs start pausing.
                Text(MenuBarState.memoryUsedText(snapshot))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(tone == .good ? Color.secondary : tone.color)
                    .help("\(Bytes.format(used)) used, \(snapshot.memoryLevel)% free")
                Spacer(minLength: 0)
                SlotChips(meter: meter)
            }
            .zIndex(1)
            MemoryMeterView(meter: meter)
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
                            fixRow(fix, runnable: finding.runnable)
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

    private func fixRow(_ fix: String, runnable: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(fix)
                .font(.system(size: 10).monospaced())
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fix, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 9))
            }
            .help("Copy to paste into a terminal")
            if runnable {
                Button {
                    runInTerminal(fix)
                } label: {
                    Image(systemName: "play.fill").font(.system(size: 9))
                }
                .help("Run in Terminal")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private func runInTerminal(_ command: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("turnstile-fix-\(UUID().uuidString).command")
        do {
            try Health.terminalScript(for: command).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return
        }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
