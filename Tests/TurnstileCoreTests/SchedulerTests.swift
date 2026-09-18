import Testing
@testable import TurnstileCore

struct SchedulerTests {
    let gb = Bytes.gb
    let policy = SchedulerPolicy(classLimits: [.compile: 2, .test: 1, .browser: 1], reserve: 2 * Bytes.gb)

    func queued(_ id: Int64, _ cls: ResourceClass = .compile, gb estimate: UInt64 = 2, agent: Bool = true, at time: Double? = nil, bumped: Double? = nil) -> QueuedJob {
        QueuedJob(id: id, resourceClass: cls, estimate: estimate * gb, agent: agent, bumpedAt: bumped, queuedAt: time ?? Double(id), label: "job\(id), ~\(estimate) GB")
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
