import Testing
@testable import TurnstileCore

struct MemoryMeterTests {
    let gb = Bytes.gb

    func job(_ id: Int64, _ cls: ResourceClass = .compile, state: String = "running", estimate: UInt64, footprint: UInt64? = nil, held: Bool = false) -> JobSnapshot {
        JobSnapshot(
            id: id, state: state, resourceClass: cls, project: "p\(id)", key: "swift build", cwd: "/p", agent: true,
            estimate: estimate, footprint: state == "queued" ? nil : (footprint ?? 0), peak: nil, paused: state == "paused",
            clientPid: 1, childPid: nil, queuedAt: 0, startedAt: nil, waiting: nil, joiners: 0, held: held
        )
    }

    /// A 100 GB machine, so the level is free memory in GB. 1 GB reserve.
    func snapshot(level: Int = 4, running: [JobSnapshot] = [], queued: [JobSnapshot] = [], limits: [String: Int] = ["compile": 1, "test": 2]) -> StatusSnapshot {
        StatusSnapshot(memoryLevel: level, physicalMemory: 100 * Bytes.gb, reserve: Bytes.gb, limits: limits, running: running, queued: queued, recent: [], daemonPid: 1)
    }

    @Test func headroomIsWhatTheSchedulerSeesAsSpare() {
        let running = [RunningJob(id: 1, resourceClass: .compile, estimate: 3 * gb, footprint: gb)]
        #expect(Scheduler.headroom(freeMemory: 6 * gb, reserve: gb, running: running) == Int64(3 * gb))
        #expect(Scheduler.headroom(freeMemory: gb, reserve: gb, running: running) < 0)
    }

    @Test func spareMatchesTheSchedulersHeadroom() {
        let meter = MemoryMeter(snapshot(running: [job(1, estimate: 3 * gb, footprint: gb)]))
        // 4 GB free, less 1 GB reserve, less the 2 GB the job is still expected to grow into.
        #expect(meter.spare == gb)
        let running = [RunningJob(id: 1, resourceClass: .compile, estimate: 3 * gb, footprint: gb)]
        #expect(Int64(meter.spare) == Scheduler.headroom(freeMemory: 4 * gb, reserve: gb, running: running))
    }

    @Test func eachRunningJobIsASegmentWithItsCommittedGrowth() {
        let meter = MemoryMeter(snapshot(running: [job(1, estimate: 3 * gb, footprint: gb), job(2, .test, estimate: gb, footprint: 2 * gb)]))
        #expect(meter.segments.map(\.id) == [1, 2])
        #expect(meter.segments[0].used == gb && meter.segments[0].committed == 2 * gb)
        #expect(meter.segments[1].used == 2 * gb && meter.segments[1].committed == 0)
    }

    @Test func runningJobsNeverShareAHue() {
        // 548 and 554 both pick hue 2 by id.
        let meter = MemoryMeter(snapshot(running: [job(548, estimate: gb, footprint: gb), job(554, .test, estimate: gb, footprint: gb)]))
        #expect(meter.segments.map(\.hue) == [2, 3])
    }

    @Test func aJobKeepsItsHueWhenAnEarlierOneFinishes() {
        let alone = MemoryMeter(snapshot(running: [job(7, estimate: gb, footprint: gb)]))
        let together = MemoryMeter(snapshot(running: [job(3, estimate: gb, footprint: gb), job(7, .test, estimate: gb, footprint: gb)]))
        #expect(alone.segments[0].hue == together.segments[1].hue)
    }

    @Test func aJustAdmittedJobHoldsItsEstimateSoTheBarDoesntJump() {
        let before = MemoryMeter(snapshot(running: [job(1, estimate: 3 * gb, footprint: 0)]))
        let after = MemoryMeter(snapshot(running: [job(1, estimate: 3 * gb, footprint: 2 * gb)]))
        #expect(before.segments[0].width == after.segments[0].width)
    }

    @Test func memoryOutsideJobsIsItsOwnSegment() {
        // 96 GB in use, 3 GB of it by the job.
        let meter = MemoryMeter(snapshot(running: [job(1, estimate: 3 * gb, footprint: 3 * gb)]))
        #expect(meter.other == 93 * gb)
    }

    @Test func thePartsAddUpToThePhysicalMemory() {
        let meter = MemoryMeter(snapshot(running: [job(1, estimate: 3 * gb, footprint: gb)]))
        #expect(meter.span == 100 * gb)
        #expect(meter.reserveAt == 99 * gb)
    }

    @Test func overcommittedMemoryWidensTheSpanRatherThanGoingNegative() {
        // 1 GB free but the job still expects 5 GB more.
        let meter = MemoryMeter(snapshot(level: 1, running: [job(1, estimate: 6 * gb, footprint: gb)]))
        #expect(meter.spare == 0)
        #expect(meter.span >= meter.other + 6 * gb + meter.reserve)
        #expect(meter.reserveAt == meter.span - meter.reserve)
    }

    @Test func theHeadQueuedJobIsAGhostThatMayNotFit() {
        let meter = MemoryMeter(snapshot(running: [job(1, estimate: 3 * gb, footprint: gb)], queued: [job(2, .test, state: "queued", estimate: 2 * gb)]))
        #expect(meter.ghost?.id == 2)
        #expect(meter.ghost?.fits == false)
        #expect(meter.blocker == .memory)
    }

    @Test func heldJobsArentTheHeadOfTheQueue() {
        let queued = [job(2, state: "queued", estimate: 9 * gb, held: true), job(3, .test, state: "queued", estimate: gb / 2)]
        let meter = MemoryMeter(snapshot(running: [job(1, estimate: 3 * gb, footprint: gb)], queued: queued))
        #expect(meter.ghost?.id == 3)
        #expect(meter.ghost?.fits == true)
    }

    @Test func withNothingRunningTheHeadAlwaysFits() {
        let meter = MemoryMeter(snapshot(level: 5, queued: [job(1, state: "queued", estimate: 8 * gb)]))
        #expect(meter.ghost?.fits == true)
        #expect(meter.blocker == nil)
    }

    @Test func plentyOfRoomButNoSlotBlamesTheSlot() {
        let meter = MemoryMeter(snapshot(level: 75, running: [job(1, estimate: gb, footprint: gb)], queued: [job(2, state: "queued", estimate: gb)]))
        #expect(meter.ghost?.fits == true)
        #expect(meter.blocker == .slot(.compile))
    }

    @Test func slotCountsComeFromTheLimits() {
        let meter = MemoryMeter(snapshot(running: [job(1, estimate: gb, footprint: gb)], queued: [job(2, state: "queued", estimate: gb), job(3, .test, state: "queued", estimate: gb)]))
        #expect(meter.slots == [
            .init(resourceClass: .compile, running: 1, limit: 1, queued: 1),
            .init(resourceClass: .test, running: 0, limit: 2, queued: 1),
        ])
        #expect(meter.slots[0].full && !meter.slots[1].full)
    }

    @Test func noQueueNoGhost() {
        let meter = MemoryMeter(snapshot(running: [job(1, estimate: gb, footprint: gb)]))
        #expect(meter.ghost == nil && meter.blocker == nil)
    }
}
