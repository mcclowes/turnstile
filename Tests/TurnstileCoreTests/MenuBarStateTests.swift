import Testing
@testable import TurnstileCore

struct MenuBarStateTests {
    func job(_ id: Int64, state: String = "running", pausedBy: String? = nil, held: Bool = false) -> JobSnapshot {
        JobSnapshot(
            id: id, state: pausedBy != nil ? "paused" : state, resourceClass: .test, project: "api", key: "swift test", cwd: "/api",
            agent: true, estimate: Bytes.gb, footprint: nil, peak: nil, paused: pausedBy != nil, clientPid: 1, childPid: nil,
            queuedAt: 0, startedAt: nil, waiting: nil, joiners: 0, held: held, pausedBy: pausedBy
        )
    }

    func entry(_ id: Int64, _ outcome: String) -> HistoryEntry {
        HistoryEntry(id: id, project: "api", key: "swift test", outcome: outcome, exitCode: nil, peak: 7 * Bytes.gb, duration: 3, finishedAt: 0)
    }

    func snapshot(level: Int = 40, running: [JobSnapshot] = [], queued: [JobSnapshot] = [], recent: [HistoryEntry] = []) -> StatusSnapshot {
        StatusSnapshot(memoryLevel: level, physicalMemory: 16 * Bytes.gb, reserve: 0, limits: [:], running: running, queued: queued, recent: recent, daemonPid: 1)
    }

    @Test func iconShowsQueueDepthAndTrouble() {
        #expect(MenuBarState.indicator(nil) == .init(symbol: MenuBarState.idleSymbol, count: nil))
        #expect(MenuBarState.indicator(snapshot(running: [job(1)], queued: [job(2, state: "queued"), job(3, state: "queued")])) == .init(symbol: MenuBarState.busySymbol, count: 2))
        #expect(MenuBarState.indicator(snapshot(running: [job(1, pausedBy: "you")])).symbol == MenuBarState.pausedSymbol)
        #expect(MenuBarState.indicator(snapshot(level: 10, running: [job(1)])).symbol == MenuBarState.pressureSymbol)
        #expect(MenuBarState.indicator(snapshot(running: [job(1, pausedBy: "memory")])).symbol == MenuBarState.pressureSymbol)
    }

    @Test func iconOnlyTakesColourWhenSomethingWantsAttention() {
        #expect(MenuBarState.indicator(nil).tone == .neutral)
        #expect(MenuBarState.indicator(snapshot(running: [job(1)])).tone == .neutral)
        #expect(MenuBarState.indicator(snapshot(running: [job(1, pausedBy: "you")])).tone == .warning)
        #expect(MenuBarState.indicator(snapshot(level: 10)).tone == .danger)
    }

    @Test func memoryTurnsAmberBeforeItTurnsRed() {
        #expect(MenuBarState.memoryTone(60) == .good)
        #expect(MenuBarState.memoryTone(MenuBarState.tightMemoryPercent) == .good)
        #expect(MenuBarState.memoryTone(MenuBarState.tightMemoryPercent - 1) == .warning)
        #expect(MenuBarState.memoryTone(MenuBarState.lowMemoryPercent - 1) == .danger)
    }

    @Test func jobsReadTheirState() {
        #expect(MenuBarState.badge(for: job(1)) == .init("play.fill", .good))
        #expect(MenuBarState.badge(for: job(1, pausedBy: "you")).tone == .neutral)
        #expect(MenuBarState.badge(for: job(1, pausedBy: "memory")).tone == .warning)
        #expect(MenuBarState.badge(for: job(2, state: "queued", held: true)) == .init("hand.raised.fill", .warning))
        #expect(MenuBarState.stateText(for: job(1)) == "Running")
        #expect(MenuBarState.stateText(for: job(1, pausedBy: "memory")) == "Paused for memory")
        #expect(MenuBarState.stateText(for: job(2, state: "queued")) == "Queued")
        #expect(MenuBarState.stateText(for: job(2, state: "queued", held: true)) == "Held")
    }

    @Test func memoryBarOnlyAppliesToWhatIsRunning() {
        var running = job(1)
        running.estimate = 4 * Bytes.gb
        running.footprint = Bytes.gb
        #expect(MenuBarState.memoryFraction(for: running) == 0.25)
        #expect(MenuBarState.footprintTone(for: running) == .good)
        #expect(MenuBarState.memoryText(for: running) == "1 GB of ~4 GB")

        running.footprint = 6 * Bytes.gb
        #expect(MenuBarState.memoryFraction(for: running) == 1)
        #expect(MenuBarState.footprintTone(for: running) == .warning)

        var queued = job(2, state: "queued")
        queued.estimate = 2 * Bytes.gb
        #expect(MenuBarState.memoryFraction(for: queued) == nil)
        #expect(MenuBarState.memoryText(for: queued) == "~2 GB expected")
    }

    @Test func historyReadsItsOutcome() {
        #expect(MenuBarState.badge(for: entry(1, "ok")).tone == .good)
        #expect(MenuBarState.badge(for: entry(1, "killed")).tone == .danger)
        #expect(MenuBarState.badge(for: entry(1, "signaled")).tone == .danger)
        #expect(MenuBarState.badge(for: entry(1, "lost")).tone == .warning)
        #expect(MenuBarState.badge(for: entry(1, "cancelled")).tone == .neutral)
        #expect(MenuBarState.detail(for: entry(1, "ok")) == "ok · 3s · peak 7 GB")
        var failed = entry(1, "failed")
        failed.exitCode = 2
        #expect(MenuBarState.detail(for: failed).hasPrefix("failed (2) · "))
    }

    @Test func actionsFitTheJobsState() {
        #expect(MenuBarState.actions(for: job(1)).map(\.message) == ["bump", "pause", "kill"])
        #expect(MenuBarState.actions(for: job(1, pausedBy: "memory")).map(\.message) == ["bump", "resume", "kill"])
        #expect(MenuBarState.actions(for: job(2, state: "queued")).map(\.message) == ["bump", "hold", "kill"])
        #expect(MenuBarState.actions(for: job(2, state: "queued", held: true)).map(\.title) == ["Move to front", "Release", "Kill"])
    }

    @Test func notifiesOnMemoryKillsAndPausesOnly() {
        let before = snapshot(running: [job(1), job(2)], recent: [entry(5, "ok")])
        let after = snapshot(level: 6, running: [job(2, pausedBy: "memory")], recent: [entry(1, "killed"), entry(7, "cancelled"), entry(5, "ok")])
        let events = MenuBarState.events(from: before, to: after)
        #expect(events.count == 1)
        #expect(events.first?.title == "Paused #2 api swift test")
        let killed = snapshot(recent: [entry(8, "killed"), entry(5, "ok")])
        #expect(MenuBarState.events(from: before, to: killed).map(\.title) == ["Killed #8 api swift test"])
    }

    @Test func noNotificationsForWhatWasAlreadyThere() {
        let now = snapshot(running: [job(2, pausedBy: "memory")], recent: [entry(8, "killed")])
        #expect(MenuBarState.events(from: nil, to: now).isEmpty)
        #expect(MenuBarState.events(from: now, to: now).isEmpty)
        #expect(MenuBarState.events(from: now, to: nil).isEmpty)
    }
}
