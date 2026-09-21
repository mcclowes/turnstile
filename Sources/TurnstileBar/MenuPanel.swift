import AppKit
import SwiftUI
import TurnstileCore

/// The whole menu: memory at the top, jobs in the middle, the app's own switches at the bottom.
struct MenuPanel: View {
    @ObservedObject var monitor: Monitor
    @State private var showRecent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot = monitor.snapshot {
                MemoryHeader(snapshot: snapshot)
                Divider()
                body(for: snapshot)
            } else {
                idle
            }
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
        let now = Date().timeIntervalSince1970
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if snapshot.running.isEmpty && snapshot.queued.isEmpty {
                    empty
                }
                jobs("Running", snapshot.running, now: now)
                jobs("Queued", snapshot.queued, now: now)
                if !snapshot.recent.isEmpty {
                    recent(snapshot.recent)
                }
            }
            .padding(.bottom, 8)
        }
        .frame(height: Panel.listHeight(for: snapshot, showingRecent: showRecent))
    }

    @ViewBuilder
    private func jobs(_ title: String, _ jobs: [JobSnapshot], now: Double) -> some View {
        if !jobs.isEmpty {
            SectionHeader(title: title, count: jobs.count)
            ForEach(jobs, id: \.id) { job in
                JobRow(job: job, now: now) { monitor.send($0, to: job.id) }
            }
        }
    }

    @ViewBuilder
    private func recent(_ entries: [HistoryEntry]) -> some View {
        Divider().padding(.top, 8)
        Button {
            withAnimation(.snappy(duration: 0.15)) { showRecent.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text("RECENT")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(showRecent ? 90 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Panel.gutter)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        if showRecent {
            ForEach(entries, id: \.id) { entry in
                let badge = MenuBarState.badge(for: entry)
                HStack(spacing: 8) {
                    Image(systemName: badge.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(badge.tone.color)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(entry.project).font(.system(size: 11, weight: .medium))
                            Text(entry.key).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                        Text(MenuBarState.detail(for: entry))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Text("#\(entry.id)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Panel.gutter)
                .padding(.vertical, 4)
            }
        }
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
            Text("Daemon idle")
                .font(.system(size: 13, weight: .semibold))
            Text("It starts with the next gated command")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
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

/// Free memory, the number that decides what runs and what waits.
struct MemoryHeader: View {
    var snapshot: StatusSnapshot

    private var tone: MenuBarState.Tone { MenuBarState.memoryTone(snapshot.memoryLevel) }
    private var free: UInt64 { snapshot.physicalMemory / 100 * UInt64(snapshot.memoryLevel) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Gauge(value: Double(snapshot.memoryLevel), in: 0...100) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(snapshot.memoryLevel)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(tone.color)
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory free")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(Bytes.format(free)) of \(Bytes.format(snapshot.physicalMemory))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let version = snapshot.version {
                    Text(version)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            if tone != .good {
                HStack(spacing: 6) {
                    Image(systemName: MenuBarState.pressureSymbol)
                        .font(.system(size: 10))
                    Text(tone == .danger
                        ? "Memory is low. Jobs pause until it recovers."
                        : "Memory is getting tight.")
                        .font(.system(size: 11))
                }
                .foregroundStyle(tone.color)
            }
        }
        .padding(.horizontal, Panel.gutter)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}
