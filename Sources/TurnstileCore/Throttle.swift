import Foundation

/// Limits the daemon hands a job at admission.
public struct JobLimits: Codable, Equatable, Sendable {
    public var jobs: Int?
    public var nodeHeapMB: Int?

    public init(jobs: Int? = nil, nodeHeapMB: Int? = nil) {
        self.jobs = jobs
        self.nodeHeapMB = nodeHeapMB
    }
}

public enum Throttle {
    /// Parallelism and heap sized from memory pressure. Nothing is injected at normal levels; macOS idles around 30–50% free.
    /// A swapping machine gets the tightest limits whatever the level reads, since the level is what swapping distorts.
    public static func limits(memoryLevel: Int, pressure: EffectiveMemoryPressure = .normal, cpuCount: Int, config: ThrottleConfig) -> JobLimits {
        guard config.inject ?? true else { return JobLimits() }
        let level = pressure > .normal ? Swift.min(memoryLevel, 14) : memoryLevel
        var jobs = config.jobs
        if jobs == nil {
            if level < 15 { jobs = max(1, cpuCount / 4) }
            else if level < 25 { jobs = max(1, cpuCount / 2) }
        }
        var heap = config.nodeHeap.map { Int($0 / Bytes.mb) }
        if heap == nil && level < 15 { heap = 2048 }
        return JobLimits(jobs: jobs, nodeHeapMB: heap)
    }

    static let nodeTools: Set<String> = ["npm", "pnpm", "yarn", "npx", "vitest", "jest", "playwright", "tsc", "cypress"]

    /// Adds each tool's own limits to its arguments and environment, never overriding what the caller set.
    public static func inject(tool: String, args: [String], environment: [String: String], limits: JobLimits) -> (args: [String], environment: [String: String]) {
        var args = args
        var env = environment

        if let heap = limits.nodeHeapMB, nodeTools.contains(tool) {
            let options = env["NODE_OPTIONS"] ?? ""
            if !options.contains("--max-old-space-size") {
                env["NODE_OPTIONS"] = (options.isEmpty ? "" : options + " ") + "--max-old-space-size=\(heap)"
            }
        }

        guard let jobs = limits.jobs else { return (args, env) }
        func has(_ flags: [String]) -> Bool {
            args.contains { arg in
                flags.contains { flag in
                    arg == flag || arg.hasPrefix(flag + "=")
                        || (flag.count == 2 && arg.hasPrefix(flag) && Int(arg.dropFirst(2)) != nil)  // -j4
                }
            }
        }

        switch tool {
        case "swift" where args.first == "build" || args.first == "test":
            if !has(["-j", "--jobs"]) { args.insert(contentsOf: ["--jobs", "\(jobs)"], at: 1) }
            if args.first == "test" && args.contains("--parallel") && !has(["--num-workers"]) {
                args += ["--num-workers", "\(jobs)"]
            }
        case "xcodebuild":
            if !has(["-jobs"]) { args += ["-jobs", "\(jobs)"] }
        case "cargo":
            if env["CARGO_BUILD_JOBS"] == nil && !has(["-j", "--jobs"]) { env["CARGO_BUILD_JOBS"] = "\(jobs)" }
        case "go":
            let flags = env["GOFLAGS"] ?? ""
            if !flags.contains("-p=") && !has(["-p"]) {
                env["GOFLAGS"] = (flags.isEmpty ? "" : flags + " ") + "-p=\(jobs)"
            }
        case "gradle", "gradlew":
            if !has(["--max-workers"]) && !args.contains(where: { $0.hasPrefix("-Dorg.gradle.workers.max") }) {
                args.append("--max-workers=\(jobs)")
            }
        case "make", "gmake":
            // Only cap an unbounded `-j`; a make without -j is already serial.
            if let index = args.firstIndex(where: { $0 == "-j" || $0 == "--jobs" }),
               index + 1 >= args.count || Int(args[index + 1]) == nil {
                args[index] = "-j\(jobs)"
            }
        case "vitest", "jest":
            let flags = tool == "jest" ? ["--maxWorkers", "-w"] : ["--maxWorkers", "--max-workers"]
            if !has(flags) && !args.contains("--runInBand") && !args.contains("-i") {
                args.append("--maxWorkers=\(jobs)")
            }
        default:
            break
        }
        return (args, env)
    }
}

/// Pause and kill decisions for running jobs.
public enum Pressure {
    /// Ceiling above which a job is a runaway candidate. `highWaterPeak` is the command's high-water
    /// mark rather than its recent average: a cold compile can be tens of times an incremental one, and
    /// a ceiling that forgets the cold runs turns the next one into a "runaway".
    /// The floor is a share of the machine, since a fixed one is far too small on a big Mac.
    public static func ceiling(highWaterPeak: UInt64?, physicalMemory: UInt64, floorPercent: Int, config: ThrottleConfig) -> UInt64 {
        if let max = config.maxMemory { return max }
        let multiplier = config.killMultiplier ?? 3
        guard let peak = highWaterPeak else { return physicalMemory / 4 * 3 }
        let floor = physicalMemory * UInt64(Swift.max(0, Swift.min(100, floorPercent))) / 100
        return Swift.max(UInt64(Double(peak) * multiplier), floor)
    }

    /// What to do about a job past its ceiling. Being past it only makes the job a candidate: memory
    /// it isn't taking from anyone costs nothing, and ending a legitimate build costs a whole run.
    public enum Runaway: Equatable, Sendable {
        /// Past the ceiling with memory to spare. Say so once and leave it alone.
        case watch
        /// Past the ceiling with memory running out. Stop it growing, recoverably.
        case pause
        /// Past an explicit `maxMemory`, or paused and the pressure hasn't lifted.
        case kill
    }

    /// Seconds a runaway stays paused before pausing is judged to have failed. Long enough for
    /// another job to finish or for the pressure to pass, short enough that the machine isn't stuck.
    public static let runawayGrace: Double = 15

    /// `hard` is an explicit `maxMemory`: the one case where a person asked for a kill.
    /// `pressuredFor` is how long the job has already been a runaway under pressure, nil if it hasn't.
    public static func runaway(
        footprint: UInt64, ceiling: UInt64, hard: Bool, memoryLevel: Int, pressure: EffectiveMemoryPressure = .normal, pauseBelow: Int,
        pressuredFor: Double?, grace: Double = runawayGrace
    ) -> Runaway? {
        guard footprint > ceiling else { return nil }
        if hard { return .kill }
        guard memoryLevel < pauseBelow || pressure > .normal else { return .watch }
        guard let pressuredFor, pressuredFor >= grace else { return .pause }
        return .kill
    }

    public struct Candidate: Equatable, Sendable {
        public var id: Int64
        public var startedAt: Double
        public var paused: Bool
        public var pausable: Bool
        /// Paused by a person, so only a person resumes it.
        public var manual: Bool
        /// Paused for being past its ceiling. Only memory actually recovering resumes it: the rule that
        /// keeps one job running would just put the runaway straight back under the same pressure.
        public var runaway: Bool

        public init(id: Int64, startedAt: Double, paused: Bool, pausable: Bool = true, manual: Bool = false, runaway: Bool = false) {
            self.id = id
            self.startedAt = startedAt
            self.paused = paused
            self.pausable = pausable
            self.manual = manual
            self.runaway = runaway
        }
    }

    public enum Action: Equatable, Sendable {
        case pause(Int64)
        case resume(Int64)
    }

    /// Pauses the newest job when memory runs low, keeping at least one running so work progresses.
    /// Resumes the oldest paused job once pressure clears, leaving jobs a person paused alone.
    ///
    /// Swapping counts as low whatever the level reads: the kernel pages out to hold that level up,
    /// so on a machine that is already swapping it never falls to `pauseBelow`. Resuming needs both
    /// a recovered level and quiet swap, unless nothing else is running and waiting can't help.
    public static func action(memoryLevel: Int, pressure: EffectiveMemoryPressure = .normal, jobs: [Candidate], pauseBelow: Int, resumeAbove: Int) -> Action? {
        let running = jobs.filter { !$0.paused }
        if memoryLevel < pauseBelow || pressure > .normal, running.count > 1,
           let newest = running.filter(\.pausable).max(by: { $0.startedAt < $1.startedAt }),
           newest.id != running.min(by: { $0.startedAt < $1.startedAt })?.id {
            return .pause(newest.id)
        }
        let recovered = memoryLevel >= resumeAbove && pressure == .normal
        let resumable = jobs.filter { $0.paused && !$0.manual && (recovered || !$0.runaway) }
        if recovered || running.isEmpty, let oldest = resumable.min(by: { $0.startedAt < $1.startedAt }) {
            return .resume(oldest.id)
        }
        return nil
    }

    /// The job that would be paused if the kernel's pressure verdict were the trigger, where the level threshold pauses
    /// nothing. Recorded but never acted on, to learn whether that trigger would fire at the right times.
    public static func shadowPause(pressure: MemoryPressure, memoryLevel: Int, jobs: [Candidate], pauseBelow: Int, resumeAbove: Int) -> Int64? {
        guard pressure >= .warn, memoryLevel >= pauseBelow,
              case let .pause(id)? = action(memoryLevel: pauseBelow - 1, jobs: jobs, pauseBelow: pauseBelow, resumeAbove: resumeAbove)
        else { return nil }
        return id
    }
}
