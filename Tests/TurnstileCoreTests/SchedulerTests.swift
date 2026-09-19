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
    }
}
