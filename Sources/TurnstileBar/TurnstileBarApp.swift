import AppKit
import SwiftUI
import TurnstileCore

@main
struct TurnstileBarApp: App {
    @StateObject private var monitor = Monitor()

    init() {
        // No Dock icon, even when run outside the app bundle.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            let indicator = MenuBarState.indicator(monitor.snapshot)
            Image(systemName: indicator.symbol)
            if let count = indicator.count { Text("\(count)") }
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        if let snapshot = monitor.snapshot {
            let free = snapshot.physicalMemory / 100 * UInt64(snapshot.memoryLevel)
            Text("Memory \(snapshot.memoryLevel)% free (~\(Bytes.format(free)) of \(Bytes.format(snapshot.physicalMemory)))")
            Divider()
            if snapshot.running.isEmpty && snapshot.queued.isEmpty {
                Text("Nothing running or queued")
            }
            jobs("Running", snapshot.running)
            jobs("Queued", snapshot.queued)
            if !snapshot.recent.isEmpty {
                Divider()
                Menu("Recent") {
                    ForEach(snapshot.recent, id: \.id) { entry in
                        Text("#\(entry.id) \(entry.project) \(entry.key): \(entry.outcome)\(entry.duration.map { ", \(formatDuration($0))" } ?? "")")
                    }
                }
            }
        } else {
            Text("Daemon idle")
            Text("It starts with the next gated command")
        }
        if let message = monitor.message {
            Divider()
            Text(message)
        }
        Divider()
        if monitor.canLaunchAtLogin {
            Toggle("Launch at login", isOn: Binding(get: { monitor.launchAtLogin }, set: { monitor.setLaunchAtLogin($0) }))
        }
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    func jobs(_ title: String, _ jobs: [JobSnapshot]) -> some View {
        if !jobs.isEmpty {
            Text(title)
            ForEach(jobs, id: \.id) { job in
                Menu(Self.label(job)) {
                    ForEach(MenuBarState.actions(for: job), id: \.message) { action in
                        Button(action.title) { monitor.send(action.message, to: job.id) }
                    }
                }
            }
        }
    }

    static func label(_ job: JobSnapshot) -> String {
        var detail: String
        if job.state == "queued" {
            detail = job.held == true ? "held" : "queued, ~\(Bytes.format(job.estimate))"
        } else {
            detail = Bytes.format(job.footprint ?? 0)
            if job.paused { detail += job.pausedBy == "you" ? ", paused" : ", paused for memory" }
        }
        return "#\(job.id) \(job.label) · \(detail)"
    }
}
