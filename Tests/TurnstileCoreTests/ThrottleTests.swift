import Testing
@testable import TurnstileCore

struct ThrottleTests {
    @Test func injectsNothingWhenMemoryIsPlentiful() {
        #expect(Throttle.limits(memoryLevel: 70, cpuCount: 10, config: ThrottleConfig()) == JobLimits())
    }

    @Test func shrinksParallelismUnderPressure() {
        #expect(Throttle.limits(memoryLevel: 40, cpuCount: 10, config: ThrottleConfig()) == JobLimits(jobs: 5))
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

    @Test func ceilingFollowsTheUsualPeak() {
        #expect(Pressure.ceiling(usualPeak: 2 * gb, physicalMemory: 16 * gb, config: ThrottleConfig()) == 6 * gb)
        #expect(Pressure.ceiling(usualPeak: 100 * Bytes.mb, physicalMemory: 16 * gb, config: ThrottleConfig()) == 2 * gb)
        #expect(Pressure.ceiling(usualPeak: nil, physicalMemory: 16 * gb, config: ThrottleConfig()) == 12 * gb)
        #expect(Pressure.ceiling(usualPeak: 2 * gb, physicalMemory: 16 * gb, config: ThrottleConfig(maxMemory: 3 * gb)) == 3 * gb)
    }

    func job(_ id: Int64, started: Double, paused: Bool = false, pausable: Bool = true) -> Pressure.Candidate {
        Pressure.Candidate(id: id, startedAt: started, paused: paused, pausable: pausable)
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

    @Test func resumesWhenNothingElseIsRunning() {
        #expect(Pressure.action(memoryLevel: 5, jobs: [job(2, started: 2, paused: true)], pauseBelow: 8, resumeAbove: 20) == .resume(2))
    }
}
