import Testing
@testable import TurnstileCore

struct ThrottleTests {
    @Test func agentTestsAvoidBackgroundPriority() {
        #expect(ResourceClass.compile.agentPolicy == ["-b"])
        #expect(ResourceClass.test.agentPolicy == ["-c", "utility"])
        #expect(ResourceClass.browser.agentPolicy == ["-c", "utility"])
    }

    @Test func injectsNothingWhenMemoryIsPlentiful() {
        #expect(Throttle.limits(memoryLevel: 40, cpuCount: 10, config: ThrottleConfig()) == JobLimits())
    }

    @Test func shrinksParallelismUnderPressure() {
        #expect(Throttle.limits(memoryLevel: 20, cpuCount: 10, config: ThrottleConfig()) == JobLimits(jobs: 5))
        #expect(Throttle.limits(memoryLevel: 10, cpuCount: 10, config: ThrottleConfig()) == JobLimits(jobs: 2, nodeHeapMB: 2048))
    }

    @Test func configuredLimitsApplyAlwaysUnlessDisabled() {
        let config = ThrottleConfig(jobs: 3, nodeHeap: 4 * Bytes.gb)
        #expect(Throttle.limits(memoryLevel: 90, cpuCount: 10, config: config) == JobLimits(jobs: 3, nodeHeapMB: 4096))
        var off = config
        off.inject = false
        #expect(Throttle.limits(memoryLevel: 5, cpuCount: 10, config: off) == JobLimits())
    }

    func inject(_ command: String, env: [String: String] = [:], jobs: Int? = 4, heap: Int? = nil) -> ([String], [String: String]) {
        let words = command.split(separator: " ").map(String.init)
        let result = Throttle.inject(tool: words[0], args: Array(words.dropFirst()), environment: env, limits: JobLimits(jobs: jobs, nodeHeapMB: heap))
        return (result.args, result.environment)
    }

    @Test func swiftGetsJobs() {
        #expect(inject("swift build -c release").0 == ["build", "--jobs", "4", "-c", "release"])
        #expect(inject("swift build -j 2").0 == ["build", "-j", "2"])
        #expect(inject("swift test --parallel").0 == ["test", "--jobs", "4", "--parallel", "--num-workers", "4"])
    }

    @Test func eachToolGetsItsOwnKnob() {
        #expect(inject("xcodebuild build").0 == ["build", "-jobs", "4"])
        #expect(inject("cargo build").1["CARGO_BUILD_JOBS"] == "4")
        #expect(inject("cargo build -j2").1["CARGO_BUILD_JOBS"] == nil)
        #expect(inject("go test ./...", env: ["GOFLAGS": "-mod=mod"]).1["GOFLAGS"] == "-mod=mod -p=4")
        #expect(inject("gradle test").0 == ["test", "--max-workers=4"])
        #expect(inject("vitest run").0 == ["run", "--maxWorkers=4"])
        #expect(inject("jest -w 2").0 == ["-w", "2"])
    }

    @Test func makeOnlyCapsUnboundedJobs() {
        #expect(inject("make -j").0 == ["-j4"])
        #expect(inject("make -j 8 all").0 == ["-j", "8", "all"])
        #expect(inject("make all").0 == ["all"])
    }

    @Test func nodeHeapNeverOverridesTheCaller() {
        #expect(inject("npm test", jobs: nil, heap: 2048).1["NODE_OPTIONS"] == "--max-old-space-size=2048")
        #expect(inject("npm test", env: ["NODE_OPTIONS": "--enable-source-maps"], jobs: nil, heap: 2048).1["NODE_OPTIONS"]
            == "--enable-source-maps --max-old-space-size=2048")
        #expect(inject("npm test", env: ["NODE_OPTIONS": "--max-old-space-size=8192"], jobs: nil, heap: 2048).1["NODE_OPTIONS"]
            == "--max-old-space-size=8192")
        #expect(inject("cargo build", jobs: nil, heap: 2048).1["NODE_OPTIONS"] == nil)
    }
}

struct PressureTests {
    let gb = Bytes.gb

    @Test func ceilingFollowsTheHighWaterPeak() {
        #expect(Pressure.ceiling(highWaterPeak: 2 * gb, physicalMemory: 16 * gb, floorPercent: 25, config: ThrottleConfig()) == 6 * gb)
        #expect(Pressure.ceiling(highWaterPeak: nil, physicalMemory: 16 * gb, floorPercent: 25, config: ThrottleConfig()) == 12 * gb)
        #expect(Pressure.ceiling(highWaterPeak: 2 * gb, physicalMemory: 16 * gb, floorPercent: 25, config: ThrottleConfig(maxMemory: 3 * gb)) == 3 * gb)
    }

    /// A compile that usually fits in a few hundred MB still needs gigabytes after a cold rebuild,
    /// so the floor is a share of the machine rather than a fixed 2 GB.
    @Test func theFloorIsAShareOfTheMachine() {
        #expect(Pressure.ceiling(highWaterPeak: 100 * Bytes.mb, physicalMemory: 16 * gb, floorPercent: 25, config: ThrottleConfig()) == 4 * gb)
        #expect(Pressure.ceiling(highWaterPeak: 100 * Bytes.mb, physicalMemory: 64 * gb, floorPercent: 25, config: ThrottleConfig()) == 16 * gb)
        #expect(Pressure.ceiling(highWaterPeak: 100 * Bytes.mb, physicalMemory: 16 * gb, floorPercent: 0, config: ThrottleConfig()) == 300 * Bytes.mb)
    }

    func runaway(
        footprint: UInt64, ceiling: UInt64 = Bytes.gb, hard: Bool = false, memoryLevel: Int = 60,
        pressure: EffectiveMemoryPressure = .normal, pressuredFor: Double? = nil
    ) -> Pressure.Runaway? {
        Pressure.runaway(footprint: footprint, ceiling: ceiling, hard: hard, memoryLevel: memoryLevel,
                         pressure: pressure, pauseBelow: 8, pressuredFor: pressuredFor)
    }

    @Test func aJobUnderItsCeilingIsLeftAlone() {
        #expect(runaway(footprint: 500 * Bytes.mb) == nil)
        #expect(runaway(footprint: 500 * Bytes.mb, memoryLevel: 3) == nil)
    }

    /// The bug this guards: a cold rebuild passing its ceiling with most of the machine free
    /// harms nobody, and killing it costs a whole run.
    @Test func aRunawayIsOnlyWatchedWhileMemoryIsPlentiful() {
        #expect(runaway(footprint: 2 * gb) == .watch)
        #expect(runaway(footprint: 2 * gb, memoryLevel: 9) == .watch)
    }

    @Test func aRunawayUnderPressureIsPausedBeforeItIsKilled() {
        #expect(runaway(footprint: 2 * gb, memoryLevel: 3) == .pause)
        #expect(runaway(footprint: 2 * gb, memoryLevel: 3, pressuredFor: 2) == .pause)
        #expect(runaway(footprint: 2 * gb, memoryLevel: 3, pressuredFor: 30) == .kill)
    }

    @Test func swappingMakesARunawayPauseWhileTheLevelLooksHealthy() {
        #expect(runaway(footprint: 2 * gb, memoryLevel: 35, pressure: .swapping) == .pause)
    }

    /// Pressure lifting resets the escalation: the job is watched again, not killed.
    @Test func aPausedRunawayIsntKilledOncePressureLifts() {
        #expect(runaway(footprint: 2 * gb, memoryLevel: 60, pressuredFor: 30) == .watch)
    }

    @Test func anExplicitMaxMemoryKillsWhateverTheMachineIsDoing() {
        #expect(runaway(footprint: 2 * gb, hard: true) == .kill)
        #expect(runaway(footprint: 2 * gb, hard: true, memoryLevel: 100) == .kill)
        #expect(runaway(footprint: 500 * Bytes.mb, hard: true) == nil)
    }

    func job(_ id: Int64, started: Double, paused: Bool = false, pausable: Bool = true, manual: Bool = false, runaway: Bool = false) -> Pressure.Candidate {
        Pressure.Candidate(id: id, startedAt: started, paused: paused, pausable: pausable, manual: manual, runaway: runaway)
    }

    @Test func neverResumesAJobSomeonePaused() {
        #expect(Pressure.action(memoryLevel: 60, jobs: [job(1, started: 1, paused: true, manual: true)], pauseBelow: 8, resumeAbove: 20) == nil)
        let jobs = [job(1, started: 1, paused: true, manual: true), job(2, started: 2, paused: true)]
        #expect(Pressure.action(memoryLevel: 60, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == .resume(2))
    }

    @Test func aManuallyPausedJobDoesntCountAsRunning() {
        let jobs = [job(1, started: 1, paused: true, manual: true), job(2, started: 2)]
        #expect(Pressure.action(memoryLevel: 5, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == nil)
    }

    @Test func pausesTheNewestButKeepsOneRunning() {
        #expect(Pressure.action(memoryLevel: 5, jobs: [job(1, started: 1), job(2, started: 2)], pauseBelow: 8, resumeAbove: 20) == .pause(2))
        #expect(Pressure.action(memoryLevel: 5, jobs: [job(1, started: 1)], pauseBelow: 8, resumeAbove: 20) == nil)
        #expect(Pressure.action(memoryLevel: 5, jobs: [job(1, started: 1), job(2, started: 2, paused: true)], pauseBelow: 8, resumeAbove: 20) == nil)
    }

    @Test func neverPausesPeoplesJobs() {
        #expect(Pressure.action(memoryLevel: 5, jobs: [job(1, started: 1), job(2, started: 2, pausable: false)], pauseBelow: 8, resumeAbove: 20) == nil)
    }

    @Test func resumesTheOldestOnceMemoryRecovers() {
        let jobs = [job(1, started: 1), job(2, started: 2, paused: true), job(3, started: 3, paused: true)]
        #expect(Pressure.action(memoryLevel: 12, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == nil)
        #expect(Pressure.action(memoryLevel: 25, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == .resume(2))
    }

    @Test func kernelPressureWouldPauseTheJobTheLevelThresholdMisses() {
        let jobs = [job(1, started: 1), job(2, started: 2)]
        #expect(Pressure.shadowPause(pressure: .warn, memoryLevel: 30, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == 2)
        #expect(Pressure.shadowPause(pressure: .critical, memoryLevel: 30, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == 2)
        #expect(Pressure.shadowPause(pressure: .normal, memoryLevel: 30, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == nil)
        // The level threshold already pauses here, so there's nothing to learn.
        #expect(Pressure.shadowPause(pressure: .warn, memoryLevel: 5, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == nil)
        #expect(Pressure.shadowPause(pressure: .warn, memoryLevel: 30, jobs: [job(1, started: 1)], pauseBelow: 8, resumeAbove: 20) == nil)
    }

    @Test func readsKernelPressureLevels() {
        #expect(MemoryPressure(level: 1) == .normal)
        #expect(MemoryPressure(level: 2) == .warn)
        #expect(MemoryPressure(level: 4) == .critical)
        #expect(MemoryPressure(level: nil) == .normal)
        #expect(MemoryPressure(level: 3) == .normal)
        #expect(MemoryPressure.warn < .critical)
    }

    @Test func logsMemoryOnlyWhenItMovesEnough() {
        let reading = MemoryReading(level: 23, pressure: .normal, swapUsed: 0)
        #expect(reading.isWorthLogging(since: nil))
        #expect(!MemoryReading(level: 20, pressure: .normal, swapUsed: Bytes.gb).isWorthLogging(since: reading))
        #expect(MemoryReading(level: 18, pressure: .normal, swapUsed: 0).isWorthLogging(since: reading))
        #expect(MemoryReading(level: 28, pressure: .normal, swapUsed: 0).isWorthLogging(since: reading))
        #expect(MemoryReading(level: 23, pressure: .warn, swapUsed: 0).isWorthLogging(since: reading))
    }

    @Test func resumesWhenNothingElseIsRunning() {
        #expect(Pressure.action(memoryLevel: 5, jobs: [job(2, started: 2, paused: true)], pauseBelow: 8, resumeAbove: 20) == .resume(2))
    }

    /// Resuming a job that was paused for being past its ceiling, while the pressure that paused it is
    /// still on, just puts it straight back. It waits for memory to actually recover.
    @Test func aPausedRunawayWaitsForMemoryToRecover() {
        let jobs = [job(1, started: 1, paused: true, runaway: true)]
        #expect(Pressure.action(memoryLevel: 5, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == nil)
        #expect(Pressure.action(memoryLevel: 25, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == .resume(1))
    }

    /// The bug in #17: the level never fell under `pauseBelow` because swapping held it up,
    /// so nothing paused while the machine swapped 5 GB.
    @Test func pausesWhileSwappingWhateverTheLevelSays() {
        let jobs = [job(1, started: 1), job(2, started: 2)]
        #expect(Pressure.action(memoryLevel: 35, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == nil)
        #expect(Pressure.action(memoryLevel: 35, pressure: .swapping, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == .pause(2))
    }

    @Test func swappingKeepsOneJobRunningToo() {
        #expect(Pressure.action(memoryLevel: 35, pressure: .critical, jobs: [job(1, started: 1)], pauseBelow: 8, resumeAbove: 20) == nil)
    }

    @Test func doesntResumeBackIntoSwap() {
        let jobs = [job(1, started: 1), job(2, started: 2, paused: true)]
        #expect(Pressure.action(memoryLevel: 60, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == .resume(2))
        #expect(Pressure.action(memoryLevel: 60, pressure: .swapping, jobs: jobs, pauseBelow: 8, resumeAbove: 20) == nil)
    }

    /// Nothing else is running, so keeping it paused can't help anyone.
    @Test func resumesWhileSwappingWhenNothingElseRuns() {
        #expect(Pressure.action(memoryLevel: 35, pressure: .critical, jobs: [job(2, started: 2, paused: true)], pauseBelow: 8, resumeAbove: 20) == .resume(2))
    }

    @Test func swappingSizesLimitsAsIfMemoryWereShort() {
        let config = ThrottleConfig()
        #expect(Throttle.limits(memoryLevel: 40, cpuCount: 8, config: config) == JobLimits())
        #expect(Throttle.limits(memoryLevel: 40, pressure: .swapping, cpuCount: 8, config: config) == JobLimits(jobs: 2, nodeHeapMB: 2048))
    }
}
