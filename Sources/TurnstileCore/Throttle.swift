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
    public static func limits(memoryLevel: Int, cpuCount: Int, config: ThrottleConfig) -> JobLimits {
        guard config.inject ?? true else { return JobLimits() }
        var jobs = config.jobs
        if jobs == nil {
            if memoryLevel < 15 { jobs = max(1, cpuCount / 4) }
            else if memoryLevel < 25 { jobs = max(1, cpuCount / 2) }
        }
        var heap = config.nodeHeap.map { Int($0 / Bytes.mb) }
        if heap == nil && memoryLevel < 15 { heap = 2048 }
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
    /// Ceiling above which a job is treated as a runaway and killed.
    public static func ceiling(usualPeak: UInt64?, physicalMemory: UInt64, config: ThrottleConfig) -> UInt64 {
        if let max = config.maxMemory { return max }
        let multiplier = config.killMultiplier ?? 3
        if let usual = usualPeak {
            return Swift.max(UInt64(Double(usual) * multiplier), 2 * Bytes.gb)
        }
        return physicalMemory / 4 * 3
    }

    public struct Candidate: Equatable, Sendable {
        public var id: Int64
        public var startedAt: Double
        public var paused: Bool
        public var pausable: Bool
        /// Paused by a person, so only a person resumes it.
        public var manual: Bool

        public init(id: Int64, startedAt: Double, paused: Bool, pausable: Bool = true, manual: Bool = false) {
            self.id = id
            self.startedAt = startedAt
            self.paused = paused
            self.pausable = pausable
            self.manual = manual
        }
    }

    public enum Action: Equatable, Sendable {
        case pause(Int64)
        case resume(Int64)
    }

    /// Pauses the newest job when memory runs low, keeping at least one running so work progresses.
    /// Resumes the oldest paused job once pressure clears, leaving jobs a person paused alone.
    public static func action(memoryLevel: Int, jobs: [Candidate], pauseBelow: Int, resumeAbove: Int) -> Action? {
        let running = jobs.filter { !$0.paused }
        if memoryLevel < pauseBelow, running.count > 1,
           let newest = running.filter(\.pausable).max(by: { $0.startedAt < $1.startedAt }),
           newest.id != running.min(by: { $0.startedAt < $1.startedAt })?.id {
            return .pause(newest.id)
        }
        if memoryLevel >= resumeAbove || running.isEmpty,
           let oldest = jobs.filter({ $0.paused && !$0.manual }).min(by: { $0.startedAt < $1.startedAt }) {
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
