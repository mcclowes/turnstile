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

    @Test func iconShowsJobsInFlightAndTrouble() {
        #expect(MenuBarState.indicator(nil) == .init(symbol: MenuBarState.idleSymbol, count: nil))
        #expect(MenuBarState.indicator(snapshot()).count == nil)
        #expect(MenuBarState.indicator(snapshot(running: [job(1)])).count == 1)
        #expect(MenuBarState.indicator(snapshot(running: [job(1)], queued: [job(2, state: "queued"), job(3, state: "queued")])) == .init(symbol: MenuBarState.busySymbol, count: 3))
        #expect(MenuBarState.indicator(snapshot(running: [job(1, pausedBy: "you")])).symbol == MenuBarState.pausedSymbol)
        #expect(MenuBarState.indicator(snapshot(level: 10, running: [job(1)])).symbol == MenuBarState.pressureSymbol)
        #expect(MenuBarState.indicator(snapshot(running: [job(1, pausedBy: "memory")])).symbol == MenuBarState.pressureSymbol)
    }

    @Test func gatingOffBeatsEverythingElseOnTheIcon() {
        let trouble = snapshot(level: 10, running: [job(1, pausedBy: "memory")], queued: [job(2, state: "queued")])
        #expect(MenuBarState.indicator(trouble, disabled: true) == .init(symbol: MenuBarState.disabledSymbol, count: 2, tone: .danger))
        #expect(MenuBarState.indicator(nil, disabled: true) == .init(symbol: MenuBarState.disabledSymbol, count: nil, tone: .danger))
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
    }

    @Test func memoryBarOnlyAppliesToWhatIsRunning() {
        var running = job(1)
        running.estimate = 4 * Bytes.gb
        running.footprint = Bytes.gb
        #expect(MenuBarState.memoryFraction(for: running) == 0.25)
        #expect(MenuBarState.footprintTone(for: running) == .good)
        #expect(MenuBarState.memoryText(for: running) == "25% of ~4 GB")

        running.footprint = 6 * Bytes.gb
        #expect(MenuBarState.memoryFraction(for: running) == 1)
        #expect(MenuBarState.footprintTone(for: running) == .warning)
        #expect(MenuBarState.memoryText(for: running) == "150% of ~4 GB")

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
    }

    @Test func rowsOnlyRepeatStateTheSectionDoesNotAlreadySay() {
        #expect(MenuBarState.tag(for: job(1)) == nil)
        #expect(MenuBarState.tag(for: job(2, state: "queued")) == nil)
        #expect(MenuBarState.tag(for: job(1, pausedBy: "memory")) == .init(text: "Paused for memory", tone: .warning))
        #expect(MenuBarState.tag(for: job(1, pausedBy: "you")) == .init(text: "Paused", tone: .neutral))
        #expect(MenuBarState.tag(for: job(2, state: "queued", held: true)) == .init(text: "Held", tone: .warning))
    }

    @Test func memoryBarSaysItIsMemoryNotProgress() {
        var running = job(1)
        running.estimate = 4 * Bytes.gb
        running.footprint = Bytes.gb
        let help = MenuBarState.memoryHelp(for: running)
        #expect(help?.contains("1 GB in use") == true)
        #expect(help?.contains("~4 GB") == true)
        #expect(help?.contains("not progress") == true)
        #expect(MenuBarState.memoryHelp(for: job(2, state: "queued")) == nil)
    }

    @Test func recentShowsTwoUntilExpanded() {
        let entries = (1...5).map { entry(Int64($0), "ok") }
        #expect(MenuBarState.visibleRecent(entries, expanded: false).map(\.id) == [1, 2])
        #expect(MenuBarState.visibleRecent(entries, expanded: true).count == 5)
        #expect(MenuBarState.visibleRecent(Array(entries.prefix(1)), expanded: false).count == 1)
    }

    @Test func memoryHeaderReadsAsAShareOfTheMachine() {
        #expect(MenuBarState.memoryUsedText(snapshot(level: 48)) == "52% of 16 GB")
        #expect(MenuBarState.memoryUsedText(snapshot(level: 100)) == "0% of 16 GB")
    }

    @Test func outcomeIconExplainsItself() {
        #expect(MenuBarState.outcomeHelp(for: entry(1, "ok")) == "Finished fine")
        #expect(MenuBarState.outcomeHelp(for: entry(1, "lost")).hasPrefix("Lost:"))
        var failed = entry(1, "failed")
        failed.exitCode = 2
        #expect(MenuBarState.outcomeHelp(for: failed) == "Failed with exit code 2")
        failed.log = "/tmp/1.log"
        #expect(MenuBarState.outcomeHelp(for: failed) == "Failed with exit code 2. Click to open its output.")
    }

    @Test func recentOnlyNamesOutcomesThatWereNotFine() {
        #expect(MenuBarState.outcomeNote(for: entry(1, "ok")) == nil)
        #expect(MenuBarState.outcomeNote(for: entry(1, "killed")) == "killed")
        var failed = entry(1, "failed")
        failed.exitCode = 2
        #expect(MenuBarState.outcomeNote(for: failed) == "exit 2")
    }

    @Test func promotionExplainsItselfAndSkipsTheHeadOfTheQueue() {
        let queue = [job(2, state: "queued"), job(3, state: "queued")]
        #expect(!MenuBarState.canPromote(queue[0], in: queue))
        #expect(MenuBarState.canPromote(queue[1], in: queue))
        #expect(MenuBarState.canPromote(job(1), in: [job(1)]))
        let bump = MenuBarState.actions(for: queue[1])[0]
        #expect(bump.help.contains("next"))
        #expect(MenuBarState.actions(for: job(1)).allSatisfy { !$0.help.isEmpty })
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
        let killed = snapshot(running: [job(2)], recent: [entry(8, "killed"), entry(5, "ok")])
        #expect(MenuBarState.events(from: before, to: killed).map(\.title) == ["Killed #8 api swift test"])
    }

    func yours(_ job: JobSnapshot, queuedAt: Double = 0, startedAt: Double? = nil) -> JobSnapshot {
        var job = job
        job.agent = false
        job.queuedAt = queuedAt
        job.startedAt = startedAt
        return job
    }

    @Test func pausesCarryTheJobSoTheNotificationCanActOnIt() {
        let events = MenuBarState.events(from: snapshot(running: [job(2)]), to: snapshot(running: [job(2, pausedBy: "memory")]))
        #expect(events.map(\.kind) == [.memoryPause])
        #expect(events.first?.job == 2)
        #expect(MenuBarState.Event.Kind.memoryPause.actions.map(\.message) == ["resume", "kill"])
        #expect(MenuBarState.Event.Kind.runawayKill.actions.isEmpty)
    }

    @Test func notifiesWhenYourLongWaitEnds() {
        let before = snapshot(running: [job(1)], queued: [yours(job(2, state: "queued"), queuedAt: 100)])
        let after = snapshot(running: [yours(job(2), queuedAt: 100, startedAt: 340)])
        let events = MenuBarState.events(from: before, to: after)
        #expect(events.map(\.kind) == [.longWait])
        #expect(events.first?.title == "Started #2 api swift test")
        #expect(events.first?.body == "After waiting 4m.")
    }

    @Test func shortWaitsAndAgentsWaitsStaySilent() {
        let before = snapshot(running: [job(1)], queued: [yours(job(2, state: "queued"), queuedAt: 100), job(3, state: "queued")])
        let after = snapshot(running: [yours(job(2), queuedAt: 100, startedAt: 130), { var j = job(3); j.startedAt = 1000; return j }()])
        #expect(MenuBarState.events(from: before, to: after).isEmpty)
    }

    @Test func notifiesWhenYourRunFailsButNotAnAgents() {
        var failed = entry(2, "failed")
        failed.exitCode = 1
        let before = snapshot(running: [job(1), yours(job(2)), job(3)], recent: [entry(0, "ok")])
        let after = snapshot(running: [job(1)], recent: [entry(3, "failed"), failed, entry(0, "ok")])
        let events = MenuBarState.events(from: before, to: after)
        #expect(events.map(\.kind) == [.ownFailure])
        #expect(events.first?.title == "Failed #2 api swift test")
        #expect(events.first?.body == "It exited with code 1.")
    }

    @Test func notifiesWhenTheQueueDrains() {
        let busy = snapshot(running: [job(1)], queued: [job(2, state: "queued")])
        let idle = snapshot()
        #expect(MenuBarState.events(from: busy, to: idle).map(\.kind) == [.queueDrained])
        #expect(MenuBarState.events(from: idle, to: idle).isEmpty)
    }

    @Test func routineNewsWaitsForFocusToEndAndOnlyTheQueueDrainIsOffByDefault() {
        typealias Kind = MenuBarState.Event.Kind
        #expect(Kind.allCases.filter { !$0.isOnByDefault } == [.queueDrained])
        #expect(Kind.memoryPause.urgency == .timeSensitive)
        #expect(Kind.queueDrained.urgency == .passive)
        #expect([Kind.longWait, .ownFailure, .runawayKill].allSatisfy { $0.urgency == .active })
        #expect(Kind.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test func noNotificationsForWhatWasAlreadyThere() {
        let now = snapshot(running: [job(2, pausedBy: "memory")], recent: [entry(8, "killed")])
        #expect(MenuBarState.events(from: nil, to: now).isEmpty)
        #expect(MenuBarState.events(from: now, to: now).isEmpty)
        #expect(MenuBarState.events(from: now, to: nil).isEmpty)
    }

    @Test("A wait with a known end counts down between polls", .bug(id: 44))
    func waitsCountDownLive() {
        var queued = job(2, state: "queued")
        queued.waiting = Scheduler.message(for: .memory(need: 4 * Bytes.gb, free: Bytes.gb, running: ["a"], eta: 200))
        queued.startsAt = 1000
        #expect(MenuBarState.waitingText(for: queued, now: 800) == "waiting for memory, needs ~4 GB, ~1 GB spare, starts in ~4m (running: a)")
        #expect(MenuBarState.waitingText(for: queued, now: 958) == "waiting for memory, needs ~4 GB, ~1 GB spare, starts in 42s (running: a)")
        #expect(MenuBarState.waitingText(for: queued, now: 1003) == "waiting for memory, needs ~4 GB, ~1 GB spare, should start any moment (running: a)")
    }

    @Test func waitsWithoutAnExpectedStartReadAsSent() {
        var queued = job(2, state: "queued")
        #expect(MenuBarState.waitingText(for: queued, now: 0) == nil)
        queued.waiting = Scheduler.message(for: .slots(.test, running: ["a"]))
        #expect(MenuBarState.waitingText(for: queued, now: 0) == "waiting for a test slot (running: a)")
    }

    @Test func rowsShowOnlyTheReasonAndWhenItEnds() {
        var queued = job(2, state: "queued")
        #expect(MenuBarState.waitingHeadline(for: queued, now: 0) == nil)
        queued.waiting = Scheduler.message(for: .memory(need: 4 * Bytes.gb, free: Bytes.gb, running: ["a"], eta: 200))
        #expect(MenuBarState.waitingHeadline(for: queued, now: 0) == "Waiting for memory")
        queued.startsAt = 1000
        #expect(MenuBarState.waitingHeadline(for: queued, now: 958) == "Waiting for memory, starts in 42s")
        queued.waiting = Scheduler.message(for: .slots(.test, running: ["a"]))
        queued.startsAt = nil
        #expect(MenuBarState.waitingHeadline(for: queued, now: 0) == "Waiting for a test slot")
    }
}
