import Testing
@testable import TurnstileCore

struct SchedulerTests {
    let gb = Bytes.gb
    let policy = SchedulerPolicy(classLimits: [.compile: 2, .test: 1, .browser: 1], reserve: 2 * Bytes.gb)

    func queued(_ id: Int64, _ cls: ResourceClass = .compile, gb estimate: UInt64 = 2, agent: Bool = true, at time: Double? = nil, bumped: Double? = nil, held: Bool = false) -> QueuedJob {
        QueuedJob(id: id, resourceClass: cls, estimate: estimate * gb, agent: agent, bumpedAt: bumped, queuedAt: time ?? Double(id), label: "job\(id), ~\(estimate) GB", held: held)
    }

    @Test func heldJobsAreNeverAdmitted() {
        let decision = Scheduler.decide(queue: [queued(1, held: true)], running: [], freeMemory: 10 * gb, policy: policy)
        #expect(decision.admit.isEmpty)
        #expect(decision.waiting[1] == .held)
    }

    @Test func heldJobsDontHoldUpOthers() {
        let running = [RunningJob(id: 9, resourceClass: .compile, estimate: 2 * gb, footprint: 2 * gb, label: "r")]
        let decision = Scheduler.decide(queue: [queued(1, gb: 60, held: true), queued(2, .test, gb: 1)], running: running, freeMemory: 7 * gb, policy: policy)
        #expect(decision.admit == [2])
        let test = [RunningJob(id: 9, resourceClass: .test, estimate: gb, footprint: gb)]
        let queue = Scheduler.decide(queue: [queued(1, .test, held: true), queued(2, .test)], running: test, freeMemory: 12 * gb, policy: policy)
        #expect(queue.waiting[2] == .slots(.test, running: [""]))
    }

    @Test func releasingMakesAHeldJobEligible() {
        let held = Scheduler.decide(queue: [queued(1, held: true)], running: [], freeMemory: 10 * gb, policy: policy)
        let released = Scheduler.decide(queue: [queued(1)], running: [], freeMemory: 10 * gb, policy: policy)
        #expect(held.admit.isEmpty && released.admit == [1])
    }

    @Test func admitsWhatFits() {
        let decision = Scheduler.decide(queue: [queued(1), queued(2)], running: [], freeMemory: 10 * gb, policy: policy)
        #expect(decision.admit == [1, 2])
    }

    @Test func headOfQueueAlwaysStartsOnAnIdleMachine() {
        let decision = Scheduler.decide(queue: [queued(1, gb: 12)], running: [], freeMemory: 3 * gb, policy: policy)
        #expect(decision.admit == [1])
    }

    @Test func memoryBlocksEverythingBehind() {
        let running = [RunningJob(id: 9, resourceClass: .compile, estimate: 2 * gb, footprint: 2 * gb, label: "r")]
        let decision = Scheduler.decide(queue: [queued(1, gb: 6), queued(2, .test, gb: 1)], running: running, freeMemory: 7 * gb, policy: policy)
        #expect(decision.admit.isEmpty)
        #expect(decision.waiting[1] == .memory(need: 6 * gb, free: 5 * gb, running: ["r"]))
        #expect(decision.waiting[2] == .queue(ahead: 1, next: "job1, ~6 GB"))
    }

    @Test func smallJobsStartAheadOfAMemoryBlockedJob() {
        var backfill = policy
        backfill.backfillMax = gb
        let running = [RunningJob(id: 9, resourceClass: .compile, estimate: 2 * gb, footprint: 2 * gb, label: "r")]
        let queue = [queued(1, gb: 6, at: 100), queued(2, .test, gb: 1, at: 110), queued(3, .browser, gb: 2, at: 120)]
        let decision = Scheduler.decide(queue: queue, running: running, freeMemory: 7 * gb, policy: backfill, now: 130)
        #expect(decision.admit == [2])
        #expect(decision.skipped == [2: "job1, ~6 GB"])
        #expect(decision.waiting[3] == .queue(ahead: 1, next: "job1, ~6 GB"))
    }

    @Test func nothingSkipsAMemoryBlockedJobOnceItHasWaitedLongEnough() {
        var backfill = policy
        backfill.backfillMax = gb
        let running = [RunningJob(id: 9, resourceClass: .compile, estimate: 2 * gb, footprint: 2 * gb, label: "r")]
        let queue = [queued(1, gb: 6, at: 100), queued(2, .test, gb: 1, at: 110)]
        let decision = Scheduler.decide(queue: queue, running: running, freeMemory: 7 * gb, policy: backfill, now: 100 + backfill.backfillAge)
        #expect(decision.admit.isEmpty)
        #expect(decision.waiting[2] == .queue(ahead: 1, next: "job1, ~6 GB"))
    }

    @Test func backfilledJobsMustStillFit() {
        var backfill = policy
        backfill.backfillMax = gb
        let running = [RunningJob(id: 9, resourceClass: .compile, estimate: 2 * gb, footprint: 2 * gb, label: "r")]
        let queue = [queued(1, gb: 6, at: 100), queued(2, .test, gb: 1, at: 110)]
        let decision = Scheduler.decide(queue: queue, running: running, freeMemory: 2 * gb + gb / 2, policy: backfill, now: 110)
        #expect(decision.admit.isEmpty)
    }

    func running(_ id: Int64, _ cls: ResourceClass = .compile, gb estimate: UInt64 = 2, usual: Double? = nil, elapsed: Double = 0) -> RunningJob {
        RunningJob(id: id, resourceClass: cls, estimate: estimate * gb, footprint: estimate * gb, label: "r\(id)", usualDuration: usual, elapsed: elapsed)
    }

    @Test func aJobGoesAheadIfItShouldFinishBeforeTheBlockerCouldStart() {
        var backfill = policy
        backfill.backfillMax = gb
        var quick = queued(2, .test, gb: 2, at: 110)
        quick.duration = 60
        // The blocker fits once r9 finishes, in ~300s. Too big and too late for the size-and-age rule.
        let decision = Scheduler.decide(queue: [queued(1, gb: 6, at: 100), quick], running: [running(9, usual: 400, elapsed: 100)],
                                        freeMemory: 7 * gb, policy: backfill, now: 100 + backfill.backfillAge)
        #expect(decision.admit == [2])
        #expect(decision.skipped == [2: "job1, ~6 GB"])
    }

    @Test func aSmallJobThatWouldOutlastTheBlockerWaits() {
        var backfill = policy
        backfill.backfillMax = gb
        var slow = queued(2, .test, gb: 1, at: 110)
        slow.duration = 600
        let decision = Scheduler.decide(queue: [queued(1, gb: 6, at: 100), slow], running: [running(9, usual: 400, elapsed: 100)],
                                        freeMemory: 7 * gb, policy: backfill, now: 110)
        #expect(decision.admit.isEmpty)
        #expect(decision.waiting[2] == .queue(ahead: 1, next: "job1, ~6 GB"))
    }

    @Test func unknownRunningTimesFallBackToSizeAndAge() {
        var backfill = policy
        backfill.backfillMax = gb
        var slow = queued(2, .test, gb: 1, at: 110)
        slow.duration = 600
        let running = [running(9, usual: 400, elapsed: 100), running(8, .browser, gb: 0)]
        let decision = Scheduler.decide(queue: [queued(1, gb: 6, at: 100), slow], running: running, freeMemory: 7 * gb, policy: backfill, now: 110)
        #expect(decision.admit == [2])
    }

    @Test func aJobPastItsUsualTimeHasNoKnownRemainder() {
        #expect(running(9, usual: 400, elapsed: 100).remaining == 300)
        #expect(running(9, usual: 400, elapsed: 450).remaining == nil)
        #expect(running(9).remaining == nil)
    }

    @Test func waitsCarryAnExpectedStart() {
        let memory = Scheduler.decide(queue: [queued(1, gb: 6)], running: [running(9, usual: 400, elapsed: 100)], freeMemory: 7 * gb, policy: policy)
        #expect(memory.waiting[1] == .memory(need: 6 * gb, free: 5 * gb, running: ["r9"], eta: 300))
        let slots = Scheduler.decide(queue: [queued(1, .test, gb: 1)], running: [running(9, .test, gb: 1, usual: 90, elapsed: 60)], freeMemory: 12 * gb, policy: policy)
        #expect(slots.waiting[1] == .slots(.test, running: ["r9"], eta: 30))
    }

    @Test func onlySlotAndMemoryWaitsHaveAnExpectedStart() {
        #expect(WaitReason.memory(need: gb, free: 0, running: [], eta: 45).eta == 45)
        #expect(WaitReason.slots(.test, running: [], eta: 30).eta == 30)
        #expect(WaitReason.slots(.test, running: []).eta == nil)
        #expect(WaitReason.queue(ahead: 1, next: "a").eta == nil)
        #expect(WaitReason.swapping(running: []).eta == nil)
        #expect(WaitReason.held.eta == nil)
    }

    @Test func expectedStartsReadCoarsely() {
        #expect(Scheduler.message(for: .memory(need: 4 * gb, free: gb / 2, running: ["a"], eta: 45))
            == "waiting for memory, needs ~4 GB, ~512 MB spare, starts in under a minute (running: a)")
        #expect(Scheduler.message(for: .slots(.test, running: ["a"], eta: 61))
            == "waiting for a test slot, starts in ~2m (running: a)")
    }

    @Test func backfillLimitScalesWithRAM() {
        #expect(SchedulerPolicy.backfillMax(physicalMemory: 8 * gb) == 512 * Bytes.mb)
        #expect(SchedulerPolicy.backfillMax(physicalMemory: 64 * gb) == 64 * gb / 20)
    }

    @Test func runningJobsStillGrowingReserveTheirMemory() {
        let running = [RunningJob(id: 9, resourceClass: .compile, estimate: 6 * gb, footprint: 1 * gb)]
        let decision = Scheduler.decide(queue: [queued(1, gb: 2)], running: running, freeMemory: 8 * gb, policy: policy)
        #expect(decision.admit.isEmpty)
    }

    @Test func fullClassDoesNotBlockOtherClasses() {
        let running = [RunningJob(id: 9, resourceClass: .test, estimate: gb, footprint: gb)]
        let decision = Scheduler.decide(queue: [queued(1, .test, gb: 1), queued(2, .compile, gb: 1)], running: running, freeMemory: 12 * gb, policy: policy)
        #expect(decision.admit == [2])
        #expect(decision.waiting[1] == .slots(.test, running: [""]))
    }

    @Test func reportsPlaceInQueueWithinAClass() {
        let running = [RunningJob(id: 9, resourceClass: .test, estimate: gb, footprint: gb)]
        let decision = Scheduler.decide(queue: [queued(1, .test, gb: 4), queued(2, .test), queued(3, .test)], running: running, freeMemory: 12 * gb, policy: policy)
        #expect(decision.waiting[3] == .queue(ahead: 2, next: "job1, ~4 GB"))
        #expect(Scheduler.message(for: decision.waiting[3]!) == "waiting, 2 ahead (job1, ~4 GB)")
    }

    @Test func peopleGoBeforeAgentsAndBumpsGoFirst() {
        let order = Scheduler.order([queued(1, at: 1), queued(2, agent: false, at: 2), queued(3, at: 3, bumped: 10)]).map(\.id)
        #expect(order == [3, 2, 1])
    }

    @Test func messagesReadNaturally() {
        #expect(Scheduler.message(for: .memory(need: 4 * gb, free: gb / 2, running: ["a", "b", "c"]))
            == "waiting for memory, needs ~4 GB, ~512 MB spare (running: a; b; +1 more)")
        #expect(Scheduler.message(for: .slots(.test, running: ["other-repo swift test, ~4 GB"]))
            == "waiting for a test slot (running: other-repo swift test, ~4 GB)")
        #expect(Scheduler.message(for: .swapping(running: ["a", "b"]))
            == "waiting, the machine is swapping (running: a; b)")
    }

    /// The bug in #17: free memory looks ample because the kernel is swapping to keep the level up,
    /// so the scheduler admits job after job into room that isn't there.
    @Test func nothingIsAdmittedWhileTheMachineSwaps() {
        let running = [RunningJob(id: 9, resourceClass: .compile, estimate: 2 * gb, footprint: 2 * gb, label: "r")]
        let queue = [queued(1, gb: 2), queued(2, .test, gb: 1), queued(3, .browser, gb: 1)]
        let admitted = Scheduler.decide(queue: queue, running: running, freeMemory: 12 * gb, policy: policy)
        #expect(admitted.admit == [1, 2, 3])

        let decision = Scheduler.decide(queue: queue, running: running, freeMemory: 12 * gb, policy: policy, pressure: .swapping)
        #expect(decision.admit.isEmpty)
        #expect(decision.waiting[1] == .swapping(running: ["r"]))
        #expect(decision.waiting[3] == .swapping(running: ["r"]))
    }

    /// Small jobs slip past a memory-blocked job, but not past a swapping machine.
    @Test func swappingStopsBackfillToo() {
        var backfill = policy
        backfill.backfillMax = gb
        let running = [RunningJob(id: 9, resourceClass: .compile, estimate: 2 * gb, footprint: 2 * gb, label: "r")]
        let queue = [queued(1, gb: 6, at: 100), queued(2, .test, gb: 1, at: 110)]
        let decision = Scheduler.decide(queue: queue, running: running, freeMemory: 7 * gb, policy: backfill, now: 130, pressure: .swapping)
        #expect(decision.admit.isEmpty)
        #expect(decision.skipped.isEmpty)
    }

    /// Waiting can't free memory when nothing is running, and a held job stays held either way.
    @Test func swappingStillLetsAnIdleMachineStart() {
        let queue = [queued(1, gb: 12), queued(2, held: true)]
        let decision = Scheduler.decide(queue: queue, running: [], freeMemory: 3 * gb, policy: policy, pressure: .critical)
        #expect(decision.admit == [1])
        #expect(decision.waiting[2] == .held)
    }

    @Test func aHeldJobReadsAsHeldWhileSwapping() {
        let running = [RunningJob(id: 9, resourceClass: .compile, estimate: 2 * gb, footprint: 2 * gb, label: "r")]
        let decision = Scheduler.decide(queue: [queued(1, held: true)], running: running, freeMemory: 12 * gb, policy: policy, pressure: .swapping)
        #expect(decision.waiting[1] == .held)
    }

    func pausedJob(_ id: Int64, since: Double, gb estimate: UInt64 = 1) -> RunningJob {
        RunningJob(id: id, resourceClass: .compile, estimate: estimate * gb, footprint: estimate * gb / 2, label: "p", pausedForMemorySince: since)
    }

    /// Memory recovers the moment a job is paused, but that room is the paused job's to resume into.
    /// A big job filling it would just take the next pause itself.
    @Test func aBigJobWaitsForAJobPausedForMemory() {
        var backfill = policy
        backfill.backfillMax = gb
        let running = [RunningJob(id: 8, resourceClass: .compile, estimate: 4 * gb, footprint: 4 * gb, label: "r"), pausedJob(9, since: 100)]
        let decision = Scheduler.decide(queue: [queued(1, .test, gb: 2), queued(2, held: true)], running: running, freeMemory: 10 * gb, policy: backfill, now: 110)
        #expect(decision.admit.isEmpty)
        #expect(decision.waiting[1] == .resuming(paused: "p"))
        #expect(decision.waiting[2] == .held)
        #expect(Scheduler.message(for: .resuming(paused: "p")) == "waiting for p to resume first, it was paused for memory")
    }

    @Test func aSmallJobThatFitsMayStartAheadOfAPausedJob() {
        var backfill = policy
        backfill.backfillMax = gb
        let decision = Scheduler.decide(queue: [queued(1, .test, gb: 1)], running: [pausedJob(9, since: 100)], freeMemory: 10 * gb, policy: backfill, now: 110)
        #expect(decision.admit == [1])
        #expect(decision.skipped[1] == "p")
    }

    @Test func aJobThatFinishesInTimeMayStartAheadOfAPausedJob() {
        var slow = queued(1, .test, gb: 3)
        slow.duration = 20
        var paused = pausedJob(9, since: 100)
        paused.resumesIn = 30
        #expect(Scheduler.decide(queue: [slow], running: [paused], freeMemory: 10 * gb, policy: policy, now: 110).admit == [1])
        slow.duration = 40
        #expect(Scheduler.decide(queue: [slow], running: [paused], freeMemory: 10 * gb, policy: policy, now: 110).admit.isEmpty)
    }

    /// Without this, small jobs keep the pressure up and a paused job's calm never comes.
    @Test func nothingStartsAheadOfAJobPausedTooLong() {
        var backfill = policy
        backfill.backfillMax = gb
        let decision = Scheduler.decide(queue: [queued(1, .test, gb: 1)], running: [pausedJob(9, since: 100)], freeMemory: 10 * gb, policy: backfill, now: 100 + backfill.pausedBackfillAge)
        #expect(decision.admit.isEmpty)
        #expect(decision.waiting[1] == .resuming(paused: "p"))
        #expect(backfill.pausedBackfillAge < backfill.backfillAge)
    }

    @Test func theLongestPausedJobIsTheOneThatHoldsUpTheQueue() {
        var backfill = policy
        backfill.backfillMax = gb
        var old = pausedJob(8, since: 10)
        old.label = "old"
        let decision = Scheduler.decide(queue: [queued(1, .test, gb: 1)], running: [pausedJob(9, since: 100), old], freeMemory: 10 * gb, policy: backfill, now: 110)
        #expect(decision.waiting[1] == .resuming(paused: "old"))
    }

    @Test func aJobPausedByAPersonDoesntHoldUpTheQueue() {
        let running = [RunningJob(id: 9, resourceClass: .compile, estimate: gb, footprint: gb, label: "p")]
        let decision = Scheduler.decide(queue: [queued(1, .test)], running: running, freeMemory: 10 * gb, policy: policy)
        #expect(decision.admit == [1])
    }

    /// The bug behind #2059: pressure read normal for ten seconds mid-swap, and a 2.5 GB build started into it.
    @Test func nothingStartsUntilMemoryHasBeenCalmForAWhile() {
        let running = [RunningJob(id: 9, resourceClass: .compile, estimate: 2 * gb, footprint: 2 * gb, label: "r")]
        let early = Scheduler.decide(queue: [queued(1)], running: running, freeMemory: 12 * gb, policy: policy, calmFor: 5)
        #expect(early.admit.isEmpty)
        #expect(early.waiting[1] == .settling(running: ["r"], eta: policy.settle - 5))
        #expect(Scheduler.message(for: .settling(running: ["r"], eta: 25)) == "waiting for memory to settle after swapping, starts in under a minute (running: r)")
        let settled = Scheduler.decide(queue: [queued(1)], running: running, freeMemory: 12 * gb, policy: policy, calmFor: policy.settle)
        #expect(settled.admit == [1])
        let idle = Scheduler.decide(queue: [queued(1)], running: [], freeMemory: 12 * gb, policy: policy, calmFor: 0)
        #expect(idle.admit == [1])
    }

    /// Seen live: memory flapped every few seconds and five jobs said "under a minute" for eight.
    @Test func aCalmThatBrokeDuringTheWaitPromisesNoStart() {
        let running = [RunningJob(id: 9, resourceClass: .compile, estimate: 2 * gb, footprint: 2 * gb, label: "r")]
        let decision = Scheduler.decide(queue: [queued(1, at: 10), queued(2, at: 50)], running: running, freeMemory: 12 * gb, policy: policy,
                                        calmFor: 5, calmBrokenAt: 40)
        #expect(decision.waiting[1] == .settling(running: ["r"], eta: nil))
        #expect(decision.waiting[2] == .settling(running: ["r"], eta: policy.settle - 5))
        #expect(Scheduler.message(for: .settling(running: ["r"], eta: nil)) == "waiting for memory to settle after swapping (running: r)")
    }
}
