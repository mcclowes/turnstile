import AppKit
import SwiftUI
import TurnstileCore

/// `TURNSTILE_BAR_RENDER=<dir> swift run TurnstileBar` writes the panel in each fixture state, light and dark, as PNGs and quits.
/// For reviewing layout without a daemon or a busy machine.
enum PanelFixtures {
    static func renderIfRequested() {
        guard let directory = ProcessInfo.processInfo.environment["TURNSTILE_BAR_RENDER"] else { return }
        DispatchQueue.main.async { render(to: URL(fileURLWithPath: directory)) }
    }

    private struct Fixture {
        var name: String
        var snapshot: StatusSnapshot?
        var hovered: Int64? = nil
    }

    private static var windows: [NSWindow] = []

    private static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtures = [
            Fixture(name: "busy", snapshot: busy()),
            Fixture(name: "hover-running", snapshot: busy(), hovered: 12),
            Fixture(name: "hover-queued", snapshot: busy(), hovered: 16),
            Fixture(name: "recent-expanded", snapshot: busy(queued: 0)),
            Fixture(name: "long-queue", snapshot: busy(queued: 12)),
            Fixture(name: "empty", snapshot: snapshot(level: 72)),
            Fixture(name: "disconnected", snapshot: nil),
        ]
        var pending: [(NSWindow, URL)] = []
        for fixture in fixtures {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let panel = MenuPanel(monitor: Monitor(fixture: fixture.snapshot), expandRecent: fixture.name == "recent-expanded")
                    .environment(\.previewHoveredJob, fixture.hovered)
                    .background(.background)
                let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = NSHostingView(rootView: panel)
                window.setContentSize(window.contentView!.fittingSize)
                window.orderFrontRegardless()
                windows.append(window)
                pending.append((window, directory.appendingPathComponent("\(fixture.name)-\(suffix).png")))
            }
        }
        // Give SwiftUI a few passes to measure the list and settle before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for (window, url) in pending {
                guard let view = window.contentView else { continue }
                window.setContentSize(view.fittingSize)
                view.layoutSubtreeIfNeeded()
                guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: image)
                try? image.representation(using: .png, properties: [:])?.write(to: url)
                print(url.path)
            }
            exit(0)
        }
    }

    private static let now = Date().timeIntervalSince1970

    private static func snapshot(level: Int, running: [JobSnapshot] = [], queued: [JobSnapshot] = [], recent: [HistoryEntry] = []) -> StatusSnapshot {
        StatusSnapshot(memoryLevel: level, physicalMemory: 32 * Bytes.gb, reserve: 3 * Bytes.gb, limits: [:], running: running, queued: queued, recent: recent, daemonPid: 1)
    }

    private static func busy(queued count: Int = 4) -> StatusSnapshot {
        let running = [
            job(12, .compile, "payments-reconciliation-service", "swift build --configuration release --product ReconciliationWorker", estimate: 6, footprint: 3.4, started: 134, joiners: 2),
            job(13, .test, "web", "npm run test:e2e -- --project=chromium --grep checkout", estimate: 2, footprint: 2.3, started: 48, pausedBy: "memory"),
        ]
        let reasons = [
            "waiting for memory, needs ~4 GB, ~1.2 GB spare, starts in ~1m (running: payments-reconciliation-service swift build)",
            "waiting for a compile slot (1 of 1 in use)",
            "held; release it to let it start",
            "waiting behind #15",
        ]
        let keys = [
            ("api", "swift test --parallel --filter SchedulerTests"),
            ("mobile-app-with-a-very-long-project-name", "xcodebuild -scheme App -destination 'platform=iOS Simulator,name=iPhone 17' build"),
            ("docs", "npm run build"),
            ("infra", "cargo build --release"),
        ]
        let queued = (0..<count).map { index -> JobSnapshot in
            let (project, key) = keys[index % keys.count]
            var queued = job(Int64(14 + index), index % 2 == 0 ? .test : .compile, project, key, estimate: Double(2 + index % 3), queuedAt: 30 + 25 * Double(index))
            queued.waiting = reasons[index % reasons.count]
            queued.held = index % reasons.count == 2
            return queued
        }
        let outcomes: [(String, Int32?)] = [("ok", nil), ("failed", 1), ("ok", nil), ("killed", nil), ("superseded", nil)]
        let recent = outcomes.enumerated().map { index, outcome in
            HistoryEntry(id: Int64(11 - index), project: ["api", "web", "docs", "mobile-app", "api"][index], key: ["swift test", "npm run lint -- --max-warnings 0", "npm run build", "xcodebuild build", "swift build"][index], outcome: outcome.0, exitCode: outcome.1, peak: UInt64(Double(Bytes.gb) * [1.8, 0.6, 1.1, 9.4, 3.2][index]), duration: [94, 21, 38, 612, 150][index], finishedAt: now - 60 * Double(index + 1))
        }
        return snapshot(level: 24, running: running, queued: queued, recent: recent)
    }

    private static func job(_ id: Int64, _ resourceClass: ResourceClass, _ project: String, _ key: String, estimate: Double, footprint: Double? = nil, started: Double? = nil, queuedAt: Double = 200, joiners: Int = 0, pausedBy: String? = nil) -> JobSnapshot {
        let gb = { (value: Double) in UInt64(value * Double(Bytes.gb)) }
        return JobSnapshot(
            id: id, state: started == nil ? "queued" : (pausedBy == nil ? "running" : "paused"), resourceClass: resourceClass, project: project, key: key, cwd: "/Users/dev/\(project)",
            agent: id % 2 == 0, estimate: gb(estimate), footprint: footprint.map(gb), peak: footprint.map(gb), paused: pausedBy != nil, clientPid: 1, childPid: nil,
            queuedAt: now - (started ?? 0) - queuedAt, startedAt: started.map { now - $0 }, waiting: nil, joiners: joiners, pausedBy: pausedBy
        )
    }
}
