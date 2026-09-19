import Darwin
import Foundation

public enum SystemMemory {
    /// Percent of memory the kernel considers available (`kern.memorystatus_level`).
    /// `TURNSTILE_MEMORY_LEVEL_FILE` substitutes a file's contents, for tests.
    public static func level(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        if let path = environment["TURNSTILE_MEMORY_LEVEL_FILE"],
           let text = try? String(contentsOfFile: path, encoding: .utf8),
           let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }
        return sysctlInt("kern.memorystatus_level").map(Int.init) ?? 100
    }

    public static var physical: UInt64 {
        sysctlInt("hw.memsize").map(UInt64.init) ?? 8 * Bytes.gb
    }

    public static var cpuCount: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    /// The kernel's own pressure verdict. It can say warn while `level` still reads 30% or more, because
    /// compressed and swapped pages count as available. Normal while the level is faked for tests.
    public static func pressure(environment: [String: String] = ProcessInfo.processInfo.environment) -> MemoryPressure {
        if environment["TURNSTILE_MEMORY_LEVEL_FILE"] != nil { return .normal }
        return MemoryPressure(level: sysctlInt("kern.memorystatus_vm_pressure_level"))
    }

    public static var swapUsed: UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    public static func free(level: Int) -> UInt64 {
        physical / 100 * UInt64(max(0, min(100, level)))
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        if size == 4 {
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int64(value)
        }
        var value: Int64 = 0
        size = 8
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

public enum MemoryPressure: Int, Comparable, Sendable {
    case normal = 1, warn = 2, critical = 4

    /// From `kern.memorystatus_vm_pressure_level`. Anything unrecognised counts as normal.
    public init(level: Int64?) {
        self = level.flatMap { MemoryPressure(rawValue: Int($0)) } ?? .normal
    }

    public static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool { lhs.rawValue < rhs.rawValue }

    public var name: String {
        switch self {
        case .normal: return "normal"
        case .warn: return "warn"
        case .critical: return "critical"
        }
    }
}

public struct MemoryReading: Equatable, Sendable {
    public var level: Int
    public var pressure: MemoryPressure
    public var swapUsed: UInt64

    public init(level: Int, pressure: MemoryPressure, swapUsed: UInt64) {
        self.level = level
        self.pressure = pressure
        self.swapUsed = swapUsed
    }

    public static func now(environment: [String: String] = ProcessInfo.processInfo.environment) -> MemoryReading {
        MemoryReading(level: SystemMemory.level(environment: environment), pressure: SystemMemory.pressure(environment: environment), swapUsed: SystemMemory.swapUsed)
    }

    /// A new pressure verdict, or a level at least 5 points from the last one logged. Swap alone follows the others.
    public func isWorthLogging(since previous: MemoryReading?) -> Bool {
        guard let previous else { return true }
        return pressure != previous.pressure || abs(level - previous.level) >= 5
    }
}

public enum ProcessTree {
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Parent of every process we can see.
    public static func parents() -> [pid_t: pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        var result: [pid_t: pid_t] = [:]
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
                result[pid] = pid_t(info.pbi_ppid)
            }
        }
        return result
    }

    /// `root` and all its descendants.
    public static func descendants(of root: pid_t, parents: [pid_t: pid_t]) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, parent) in parents { children[parent, default: []].append(pid) }
        var result: [pid_t] = []
        var stack = [root]
        var seen = Set<pid_t>()
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            if pid == root && parents[root] == nil && !isAlive(root) { continue }
            result.append(pid)
            stack += children[pid] ?? []
        }
        return result
    }

    /// Which of `candidates` is `pid` itself or one of its ancestors.
    public static func ancestor(of pid: pid_t, among candidates: Set<pid_t>, parents: [pid_t: pid_t]) -> pid_t? {
        var current = pid
        var seen = Set<pid_t>()
        while current > 1, seen.insert(current).inserted {
            if candidates.contains(current) { return current }
            guard let parent = parents[current] else { return nil }
            current = parent
        }
        return nil
    }

    public struct Lineage: Equatable, Sendable {
        /// Never reused, unlike a pid.
        public var id: UInt64
        /// The process that created this one. Unlike the ppid, it survives setsid and reparenting to launchd.
        public var creator: UInt64
    }

    /// Reads the private `proc_uniqidentifierinfo` (flavor 17): a 16-byte uuid, then the unique id and the creator's.
    /// Nil for other users' processes, or if the layout ever changes size.
    public static func lineage(_ pid: pid_t) -> Lineage? {
        let size: Int32 = 56
        var buffer = [UInt8](repeating: 0, count: Int(size))
        guard proc_pidinfo(pid, 17, 0, &buffer, size) == size else { return nil }
        return buffer.withUnsafeBytes { raw in
            Lineage(id: raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self), creator: raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
        }
    }

    /// Physical footprint, the number Activity Monitor calls "Memory".
    public static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    public static func footprint(of pids: [pid_t]) -> UInt64 {
        pids.reduce(0) { $0 + (footprint($1) ?? 0) }
    }

    public static func signal(_ pids: [pid_t], _ sig: Int32) {
        for pid in pids { kill(pid, sig) }
    }

    /// Clears background priority set by `taskpolicy -b`.
    public static func foreground(_ pids: [pid_t]) {
        for pid in pids { setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0) }
    }
}
