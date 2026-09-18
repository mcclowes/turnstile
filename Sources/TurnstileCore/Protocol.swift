import Foundation

/// One newline-delimited JSON message between a client and the daemon.
///
/// Client to daemon: `request`, `started`, `finished`, `status`, `bump`.
/// Daemon to client: `queued`, `admitted`, `joined`, `output`, `done`, `notice`, `release`, `status`, `ok`, `error`.
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

    // bump
    public var target: String?

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

    public var label: String { "\(project) \(key)" }

    public init(id: Int64, state: String, resourceClass: ResourceClass, project: String, key: String, cwd: String, agent: Bool, estimate: UInt64, footprint: UInt64?, peak: UInt64?, paused: Bool, clientPid: Int32, childPid: Int32?, queuedAt: Double, startedAt: Double?, waiting: String?, joiners: Int) {
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

    public init(memoryLevel: Int, physicalMemory: UInt64, reserve: UInt64, limits: [String: Int], running: [JobSnapshot], queued: [JobSnapshot], recent: [HistoryEntry], daemonPid: Int32, version: String? = Turnstile.version) {
        self.memoryLevel = memoryLevel
        self.physicalMemory = physicalMemory
        self.reserve = reserve
        self.limits = limits
        self.running = running
        self.queued = queued
        self.recent = recent
        self.daemonPid = daemonPid
        self.version = version
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

    public init(id: Int64, project: String, key: String, outcome: String, exitCode: Int32?, peak: UInt64?, duration: Double?, finishedAt: Double) {
        self.id = id
        self.project = project
        self.key = key
        self.outcome = outcome
        self.exitCode = exitCode
        self.peak = peak
        self.duration = duration
        self.finishedAt = finishedAt
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
