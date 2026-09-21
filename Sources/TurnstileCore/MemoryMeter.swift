import Foundation

/// Where the machine's memory is going, laid out left to right, and whether the next queued job fits.
///
/// Built from the scheduler's own arithmetic (`Scheduler.headroom`), so the picture and `turnstile status` agree.
/// Left to right: memory outside every job, each running job's footprint then the growth it's still expected to claim,
/// spare, and the reserve. `span` is usually the physical memory, wider when running jobs have been promised more than is free.
public struct MemoryMeter: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public var id: Int64
        public var label: String
        public var resourceClass: ResourceClass
        public var used: UInt64
        /// Estimated growth the scheduler already counts as taken.
        public var committed: UInt64
        public var paused: Bool

        /// Footprint plus what it's still expected to claim, so a job just admitted doesn't start at zero and jump.
        public var width: UInt64 { used + committed }
    }

    /// The job at the head of the queue, drawn where it would go if it started now.
    public struct Ghost: Equatable, Sendable {
        public var id: Int64
        public var label: String
        public var estimate: UInt64
        public var fits: Bool
    }

    public struct Slot: Equatable, Sendable {
        public var resourceClass: ResourceClass
        public var running: Int
        public var limit: Int
        public var queued: Int

        public var full: Bool { running >= limit }
    }

    /// Why the head of the queue isn't starting, when the meter can say.
    public enum Blocker: Equatable, Sendable {
        case memory
        case slot(ResourceClass)
    }

    public var other: UInt64
    public var segments: [Segment]
    public var spare: UInt64
    public var reserve: UInt64
    public var span: UInt64
    public var ghost: Ghost?
    public var blocker: Blocker?
    public var slots: [Slot]

    /// Where the reserve starts: new jobs must fit to the left of it.
    public var reserveAt: UInt64 { span - reserve }
    /// Where the ghost starts.
    public var committedEnd: UInt64 { other + segments.reduce(0) { $0 + $1.width } }

    public init(_ snapshot: StatusSnapshot) {
        let free = SystemMemory.free(level: snapshot.memoryLevel, of: snapshot.physicalMemory)
        let running = snapshot.running.map {
            RunningJob(id: $0.id, resourceClass: $0.resourceClass, estimate: $0.estimate, footprint: $0.footprint ?? 0, label: $0.label)
        }
        let headroom = Scheduler.headroom(freeMemory: free, reserve: snapshot.reserve, running: running)
        let inJobs = running.reduce(UInt64(0)) { $0 + $1.footprint }
        let inUse = snapshot.physicalMemory > free ? snapshot.physicalMemory - free : 0

        other = inUse > inJobs ? inUse - inJobs : 0
        segments = zip(snapshot.running, running).map { job, scheduled in
            Segment(id: job.id, label: job.label, resourceClass: job.resourceClass, used: scheduled.footprint, committed: scheduled.pendingGrowth, paused: job.paused)
        }
        spare = UInt64(max(0, headroom))
        reserve = snapshot.reserve
        span = max(snapshot.physicalMemory, other + segments.reduce(0) { $0 + $1.width } + spare + reserve)

        slots = ResourceClass.allCases.compactMap { cls in
            guard let limit = snapshot.limits[cls.rawValue] else { return nil }
            return Slot(
                resourceClass: cls, running: snapshot.running.filter { $0.resourceClass == cls }.count, limit: limit,
                queued: snapshot.queued.filter { $0.resourceClass == cls }.count
            )
        }

        guard let head = snapshot.queued.first(where: { $0.held != true }) else {
            ghost = nil
            blocker = nil
            return
        }
        // With nothing running the scheduler starts the head regardless, since waiting can't free memory.
        let fits = running.isEmpty || Int64(clamping: head.estimate) <= headroom
        ghost = Ghost(id: head.id, label: head.label, estimate: head.estimate, fits: fits)
        // The scheduler checks slots before memory, so a full class is the reason even when memory is short too.
        if slots.first(where: { $0.resourceClass == head.resourceClass })?.full == true {
            blocker = .slot(head.resourceClass)
        } else {
            blocker = fits ? nil : .memory
        }
    }
}
