import Foundation

/// One newline-delimited JSON message between a client and the daemon.
///
/// Client to daemon: `request`, `adopt` (a running job re-registering after a daemon restart), `started`, `finished`, `status`,
/// lifecycle commands `restart` and `stop`, and the controls `bump`, `kill`, `pause`, `resume`, `hold`, `unhold`, each with a `target`.
/// Daemon to client: `queued`, `admitted`, `joined`, `output`, `done`, `notice`, `release`, `cancelled`, `status`, `ok`, `error`.
public struct Message: Codable, Equatable, Sendable {
    public var type: String

    // request
    public var argv: [String]?
    public var tool: String?
    public var key: String?
    public var resourceClass: ResourceClass?
    public var memory: UInt64?
    public var cwd: String?
    public var root: String?
    public var fingerprint: String?
    public var agent: Bool?
    public var pausable: Bool?
    public var maxMemory: UInt64?
    public var killMultiplier: Double?
    public var throttleJobs: Int?
    public var nodeHeap: UInt64?
    public var inject: Bool?
    public var pid: Int32?
    /// The owner's output goes to a log others can follow, rather than a terminal.
    public var captures: Bool?
    public var interactive: Bool?

    // started / finished
    public var childPid: Int32?
    public var log: String?
    public var exitCode: Int32?
    public var signal: Int32?

    // replies
    public var job: Int64?
    public var text: String?
    public var limits: JobLimits?
    public var status: StatusSnapshot?

    // controls
    public var target: String?
    /// On `done`: someone killed the run, so it shouldn't be retried.
    public var cancelled: Bool?

    public init(type: String) {
        self.type = type
    }

    public static func notice(_ text: String) -> Message {
        var message = Message(type: "notice")
        message.text = text
        return message
    }

    public static func error(_ text: String) -> Message {
        var message = Message(type: "error")
        message.text = text
        return message
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) -> Message? {
        try? JSONDecoder().decode(Message.self, from: line)
    }
}

public struct JobSnapshot: Codable, Equatable, Sendable {
    public var id: Int64
    public var state: String
    public var resourceClass: ResourceClass
    public var project: String
    public var key: String
    public var cwd: String
    public var agent: Bool
    public var estimate: UInt64
    public var footprint: UInt64?
    public var peak: UInt64?
    public var paused: Bool
    public var clientPid: Int32
    public var childPid: Int32?
    public var queuedAt: Double
    public var startedAt: Double?
    public var waiting: String?
    public var joiners: Int
    /// Nil from daemons older than 0.3.
    public var held: Bool?
    /// "you" or "memory" while paused.
    public var pausedBy: String?
    /// Where the estimate came from when it isn't this project's history, e.g. "other projects".
    public var estimateSource: String?
    /// Every process the daemon counts against the job, and signals when it pauses or kills it.
    /// Nil from daemons older than 0.4, and while the job is queued.
    public var tree: [Int32]?
    /// The part of `tree` that left the job for launchd, which nothing outside the daemon can find.
    public var escapees: [Int32]?
    /// When a queued job should start, in epoch seconds, if the wait has a known end. Nil from daemons older than 0.5.
    public var startsAt: Double?
    /// Where the run's output is captured. Nil when it has a terminal, before it starts, and from older daemons.
    public var log: String?

    public var label: String { "\(project) \(key)" }

    public init(id: Int64, state: String, resourceClass: ResourceClass, project: String, key: String, cwd: String, agent: Bool, estimate: UInt64, footprint: UInt64?, peak: UInt64?, paused: Bool, clientPid: Int32, childPid: Int32?, queuedAt: Double, startedAt: Double?, waiting: String?, joiners: Int, held: Bool? = nil, pausedBy: String? = nil, estimateSource: String? = nil, tree: [Int32]? = nil, escapees: [Int32]? = nil, startsAt: Double? = nil, log: String? = nil) {
        self.id = id
        self.state = state
        self.resourceClass = resourceClass
        self.project = project
        self.key = key
        self.cwd = cwd
        self.agent = agent
        self.estimate = estimate
        self.footprint = footprint
        self.peak = peak
        self.paused = paused
        self.clientPid = clientPid
        self.childPid = childPid
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.waiting = waiting
        self.joiners = joiners
        self.held = held
        self.pausedBy = pausedBy
        self.estimateSource = estimateSource
        self.tree = tree
        self.escapees = escapees
        self.startsAt = startsAt
        self.log = log
    }
}

public struct StatusSnapshot: Codable, Equatable, Sendable {
    public var memoryLevel: Int
    public var physicalMemory: UInt64
    public var reserve: UInt64
    public var limits: [String: Int]
    public var running: [JobSnapshot]
    public var queued: [JobSnapshot]
    public var recent: [HistoryEntry]
    public var daemonPid: Int32
    /// Nil from daemons older than 0.2.
    public var version: String?
    /// Heavy processes seen running outside every job in the last hour.
    public var ungated: [EscapeRow] = []

    public init(memoryLevel: Int, physicalMemory: UInt64, reserve: UInt64, limits: [String: Int], running: [JobSnapshot], queued: [JobSnapshot], recent: [HistoryEntry], daemonPid: Int32, version: String? = Turnstile.version, ungated: [EscapeRow] = []) {
        self.memoryLevel = memoryLevel
        self.physicalMemory = physicalMemory
        self.reserve = reserve
        self.limits = limits
        self.running = running
        self.queued = queued
        self.recent = recent
        self.daemonPid = daemonPid
        self.version = version
        self.ungated = ungated
    }
}

public struct HistoryEntry: Codable, Equatable, Sendable {
    public var id: Int64
    public var project: String
    public var key: String
    public var outcome: String
    public var exitCode: Int32?
    public var peak: UInt64?
    public var duration: Double?
    public var finishedAt: Double
    /// The run's captured output, set only while the file still exists.
    public var log: String?

    public init(id: Int64, project: String, key: String, outcome: String, exitCode: Int32?, peak: UInt64?, duration: Double?, finishedAt: Double, log: String? = nil) {
        self.id = id
        self.project = project
        self.key = key
        self.outcome = outcome
        self.exitCode = exitCode
        self.peak = peak
        self.duration = duration
        self.finishedAt = finishedAt
        self.log = log
    }
}

/// Splits a byte stream into lines.
public struct LineBuffer {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<newline]))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }
}
