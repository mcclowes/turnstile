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

    public init(id: Int64, resourceClass: ResourceClass, estimate: UInt64, agent: Bool = true, bumpedAt: Double? = nil, queuedAt: Double, label: String = "", held: Bool = false) {
        self.id = id
        self.resourceClass = resourceClass
        self.estimate = estimate
        self.agent = agent
        self.bumpedAt = bumpedAt
        self.queuedAt = queuedAt
        self.label = label
        self.held = held
    }
}

public struct RunningJob: Equatable, Sendable {
    public var id: Int64
    public var resourceClass: ResourceClass
    public var estimate: UInt64
    public var footprint: UInt64
    public var label: String

    public init(id: Int64, resourceClass: ResourceClass, estimate: UInt64, footprint: UInt64 = 0, label: String = "") {
        self.id = id
        self.resourceClass = resourceClass
        self.estimate = estimate
        self.footprint = footprint
        self.label = label
    }

    /// Memory the job is still expected to claim.
    public var pendingGrowth: UInt64 { estimate > footprint ? estimate - footprint : 0 }
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
    /// All slots for this class are taken.
    case slots(ResourceClass, running: [String])
    /// Not enough free memory.
    case memory(need: UInt64, free: UInt64, running: [String])
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
    /// everything behind it, except small jobs that fit, and only until it has waited `backfillAge`,
    /// so a big job can't starve. With nothing running, the head of the queue always starts, since
    /// waiting can't free memory. Held jobs are skipped entirely.
    public static func decide(queue: [QueuedJob], running: [RunningJob], freeMemory: UInt64, policy: SchedulerPolicy, now: Double = 0) -> SchedulerDecision {
        var admit: [Int64] = []
        var waiting: [Int64: WaitReason] = [:]
        var skipped: [Int64: String] = [:]
        var counts: [ResourceClass: Int] = [:]
        for job in running { counts[job.resourceClass, default: 0] += 1 }

        let committed = running.reduce(UInt64(0)) { $0 + $1.pendingGrowth }
        var headroom = Int64(clamping: freeMemory) - Int64(clamping: policy.reserve) - Int64(clamping: committed)
        var anythingRunning = !running.isEmpty
        var memoryBlocked: QueuedJob?
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
            if let blocker = skipping,
               job.estimate > policy.backfillMax || now - blocker.queuedAt >= policy.backfillAge {
                waiting[job.id] = .queue(ahead: waitingCount, next: blocker.label)
                continue
            }
            let used = counts[job.resourceClass, default: 0]
            if used >= policy.limit(job.resourceClass) {
                if let ahead = waitingByClass[job.resourceClass], let first = ahead.first {
                    waiting[job.id] = .queue(ahead: ahead.count, next: first.label)
                } else {
                    waiting[job.id] = .slots(job.resourceClass, running: labels)
                }
                continue
            }
            if anythingRunning && Int64(clamping: job.estimate) > headroom {
                if memoryBlocked == nil { memoryBlocked = job }
                waiting[job.id] = .memory(need: job.estimate, free: UInt64(max(0, headroom)), running: labels)
                continue
            }
            if let blocker = skipping { skipped[job.id] = blocker.label }
            admit.append(job.id)
            counts[job.resourceClass, default: 0] = used + 1
            headroom -= Int64(clamping: job.estimate)
            anythingRunning = true
        }
        return SchedulerDecision(admit: admit, waiting: waiting, skipped: skipped)
    }

    public static func message(for reason: WaitReason) -> String {
        switch reason {
        case let .queue(ahead, next):
            return "waiting, \(ahead) ahead (\(next))"
        case let .slots(cls, running):
            return "waiting for a \(cls.rawValue) slot (running: \(summary(running)))"
        case let .memory(need, free, running):
            return "waiting for memory, needs ~\(Bytes.format(need)), ~\(Bytes.format(free)) spare (running: \(summary(running)))"
        case .held:
            return "held; waiting until someone releases it"
        }
    }

    static func summary(_ labels: [String]) -> String {
        if labels.isEmpty { return "nothing" }
        if labels.count <= 2 { return labels.joined(separator: "; ") }
        return labels.prefix(2).joined(separator: "; ") + "; +\(labels.count - 2) more"
    }
}
