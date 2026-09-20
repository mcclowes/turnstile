import Foundation

public struct QueuedJob: Equatable, Sendable {
    public var id: Int64
    public var resourceClass: ResourceClass
    public var estimate: UInt64
    public var agent: Bool
    /// Bumped jobs go first, most recently bumped first.
    public var bumpedAt: Double?
    public var queuedAt: Double
    public var label: String
    /// Kept in the queue, but never admitted until released.
    public var held: Bool
    /// Usual run time in seconds, if known.
    public var duration: Double?

    public init(id: Int64, resourceClass: ResourceClass, estimate: UInt64, agent: Bool = true, bumpedAt: Double? = nil, queuedAt: Double, label: String = "", held: Bool = false, duration: Double? = nil) {
        self.id = id
        self.resourceClass = resourceClass
        self.estimate = estimate
        self.agent = agent
        self.bumpedAt = bumpedAt
        self.queuedAt = queuedAt
        self.label = label
        self.held = held
        self.duration = duration
    }
}

public struct RunningJob: Equatable, Sendable {
    public var id: Int64
    public var resourceClass: ResourceClass
    public var estimate: UInt64
    public var footprint: UInt64
    public var label: String
    /// Usual run time in seconds, if known. Nil while paused, since a paused job isn't progressing.
    public var usualDuration: Double?
    /// Seconds it has spent running, not counting time paused.
    public var elapsed: Double

    public init(id: Int64, resourceClass: ResourceClass, estimate: UInt64, footprint: UInt64 = 0, label: String = "", usualDuration: Double? = nil, elapsed: Double = 0) {
        self.id = id
        self.resourceClass = resourceClass
        self.estimate = estimate
        self.footprint = footprint
        self.label = label
        self.usualDuration = usualDuration
        self.elapsed = elapsed
    }

    /// Memory the job is still expected to claim.
    public var pendingGrowth: UInt64 { estimate > footprint ? estimate - footprint : 0 }

    /// Seconds it's expected to keep running. Nil if unknown, or once it has overrun its usual time.
    public var remaining: Double? {
        guard let usualDuration, usualDuration > elapsed else { return nil }
        return usualDuration - elapsed
    }
}

public struct SchedulerPolicy: Sendable {
    public var classLimits: [ResourceClass: Int]
    public var reserve: UInt64
    /// Jobs up to this size may start ahead of a job waiting for memory, if they fit.
    public var backfillMax: UInt64
    /// Seconds a memory-blocked job can be skipped for; after that nothing starts ahead of it.
    public var backfillAge: Double

    public init(classLimits: [ResourceClass: Int], reserve: UInt64, backfillMax: UInt64 = 0, backfillAge: Double = 120) {
        self.classLimits = classLimits
        self.reserve = reserve
        self.backfillMax = backfillMax
        self.backfillAge = backfillAge
    }

    /// 5% of RAM, but at least 512 MB.
    public static func backfillMax(physicalMemory: UInt64) -> UInt64 {
        max(512 * Bytes.mb, physicalMemory / 20)
    }

    public func limit(_ cls: ResourceClass) -> Int { classLimits[cls] ?? 1 }
}

public enum WaitReason: Equatable, Sendable {
    /// Jobs ahead in the queue go first.
    case queue(ahead: Int, next: String)
    /// All slots for this class are taken. `eta` is seconds until one should free up, if known.
    case slots(ResourceClass, running: [String], eta: Double? = nil)
    /// Not enough free memory. `eta` is seconds until enough should free up, if known.
    case memory(need: UInt64, free: UInt64, running: [String], eta: Double? = nil)
    /// The machine is swapping, so free memory means nothing; nothing new starts until it settles.
    case swapping(running: [String])
    /// Someone held it; it waits until released.
    case held
}

public struct SchedulerDecision: Equatable, Sendable {
    public var admit: [Int64]
    public var waiting: [Int64: WaitReason]
    /// Jobs admitted ahead of a memory-blocked job, with that job's label.
    public var skipped: [Int64: String] = [:]
}

public enum Scheduler {
    /// Bumped first, then people ahead of agents, then first come first served.
    public static func order(_ queue: [QueuedJob]) -> [QueuedJob] {
        queue.sorted { a, b in
            switch (a.bumpedAt, b.bumpedAt) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
            if a.agent != b.agent { return !a.agent }
            if a.queuedAt != b.queuedAt { return a.queuedAt < b.queuedAt }
            return a.id < b.id
        }
    }

    /// Decides which queued jobs start now.
    ///
    /// A job blocked on a class slot doesn't hold up other classes. A job blocked on memory holds up
    /// everything behind it, except jobs that fit and won't delay it: ones expected to finish before it
    /// could start anyway, or, when run times aren't known, small jobs while it has waited less than
    /// `backfillAge`. With nothing running, the head of the queue always starts, since waiting can't
    /// free memory. Held jobs are skipped entirely.
    ///
    /// While the machine is swapping, nothing starts at all: `freeMemory` comes from a level the kernel
    /// is holding up by paging out, so it describes the stand-off rather than room for another job.
    public static func decide(queue: [QueuedJob], running: [RunningJob], freeMemory: UInt64, policy: SchedulerPolicy, now: Double = 0, pressure: MemoryPressure = .normal) -> SchedulerDecision {
        var admit: [Int64] = []
        var waiting: [Int64: WaitReason] = [:]
        var skipped: [Int64: String] = [:]
        var counts: [ResourceClass: Int] = [:]
        for job in running { counts[job.resourceClass, default: 0] += 1 }

        if pressure > .normal, !running.isEmpty {
            let labels = running.map(\.label)
            for job in queue { waiting[job.id] = job.held ? .held : .swapping(running: labels) }
            return SchedulerDecision(admit: [], waiting: waiting)
        }

        let committed = running.reduce(UInt64(0)) { $0 + $1.pendingGrowth }
        var headroom = Int64(clamping: freeMemory) - Int64(clamping: policy.reserve) - Int64(clamping: committed)
        var anythingRunning = !running.isEmpty
        var memoryBlocked: QueuedJob?
        var blockerStart: Double?
        var active = running.map { Active(resourceClass: $0.resourceClass, remaining: $0.remaining, releases: max($0.estimate, $0.footprint)) }
        let labels = running.map(\.label)
        var waitingByClass: [ResourceClass: [QueuedJob]] = [:]
        var waitingCount = 0

        for job in order(queue) {
            if job.held {
                waiting[job.id] = .held
                continue
            }
            defer {
                if waiting[job.id] != nil {
                    waitingByClass[job.resourceClass, default: []].append(job)
                    waitingCount += 1
                }
            }
            let skipping = memoryBlocked
            if let blocker = skipping, !mayGoAhead(job, of: blocker, startingIn: blockerStart, policy: policy, now: now) {
                waiting[job.id] = .queue(ahead: waitingCount, next: blocker.label)
                continue
            }
            let used = counts[job.resourceClass, default: 0]
            if used >= policy.limit(job.resourceClass) {
                if let ahead = waitingByClass[job.resourceClass], let first = ahead.first {
                    waiting[job.id] = .queue(ahead: ahead.count, next: first.label)
                } else {
                    let inClass = active.filter { $0.resourceClass == job.resourceClass }.map(\.remaining)
                    let eta = inClass.contains(nil) ? nil : inClass.compactMap { $0 }.min()
                    waiting[job.id] = .slots(job.resourceClass, running: labels, eta: eta)
                }
                continue
            }
            if anythingRunning && Int64(clamping: job.estimate) > headroom {
                let eta = expectedStart(need: job.estimate, headroom: headroom, active: active)
                if memoryBlocked == nil {
                    memoryBlocked = job
                    blockerStart = eta
                }
                waiting[job.id] = .memory(need: job.estimate, free: UInt64(max(0, headroom)), running: labels, eta: eta)
                continue
            }
            if let blocker = skipping { skipped[job.id] = blocker.label }
            admit.append(job.id)
            counts[job.resourceClass, default: 0] = used + 1
            headroom -= Int64(clamping: job.estimate)
            active.append(Active(resourceClass: job.resourceClass, remaining: job.duration, releases: job.estimate))
            anythingRunning = true
        }
        return SchedulerDecision(admit: admit, waiting: waiting, skipped: skipped)
    }

    private struct Active {
        var resourceClass: ResourceClass
        var remaining: Double?
        var releases: UInt64
    }

    private static func mayGoAhead(_ job: QueuedJob, of blocker: QueuedJob, startingIn blockerStart: Double?, policy: SchedulerPolicy, now: Double) -> Bool {
        if let blockerStart, let duration = job.duration { return duration <= blockerStart }
        return job.estimate <= policy.backfillMax && now - blocker.queuedAt < policy.backfillAge
    }

    /// Seconds until `need` fits, as active jobs finish soonest first. Nil if that depends on a job
    /// whose remaining time is unknown, since it might finish at any moment.
    private static func expectedStart(need: UInt64, headroom: Int64, active: [Active]) -> Double? {
        var finishing: [(at: Double, releases: UInt64)] = []
        for job in active {
            guard let remaining = job.remaining else { return nil }
            finishing.append((remaining, job.releases))
        }
        var room = headroom
        var start: Double = 0
        for job in finishing.sorted(by: { $0.at < $1.at }) {
            if Int64(clamping: need) <= room { break }
            room += Int64(clamping: job.releases)
            start = job.at
        }
        return start
    }

    public static func message(for reason: WaitReason) -> String {
        switch reason {
        case let .queue(ahead, next):
            return "waiting, \(ahead) ahead (\(next))"
        case let .slots(cls, running, eta):
            return "waiting for a \(cls.rawValue) slot\(startsIn(eta)) (running: \(summary(running)))"
        case let .memory(need, free, running, eta):
            return "waiting for memory, needs ~\(Bytes.format(need)), ~\(Bytes.format(free)) spare\(startsIn(eta)) (running: \(summary(running)))"
        case let .swapping(running):
            return "waiting, the machine is swapping (running: \(summary(running)))"
        case .held:
            return "held; waiting until someone releases it"
        }
    }

    /// Coarse on purpose: the message is resent whenever its text changes.
    static func startsIn(_ eta: Double?) -> String {
        guard let eta else { return "" }
        if eta < 60 { return ", starts in under a minute" }
        return ", starts in ~\(Int((eta / 60).rounded(.up)))m"
    }

    static func summary(_ labels: [String]) -> String {
        if labels.isEmpty { return "nothing" }
        if labels.count <= 2 { return labels.joined(separator: "; ") }
        return labels.prefix(2).joined(separator: "; ") + "; +\(labels.count - 2) more"
    }
}
