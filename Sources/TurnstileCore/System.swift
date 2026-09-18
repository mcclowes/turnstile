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
        /// The process that created this one. Unlike the ppid, it survives reparenting to launchd and setsid.
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
