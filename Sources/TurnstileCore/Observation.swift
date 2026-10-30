import Darwin
import Foundation

public struct ConnectionFailure: Error, Sendable {
    public var code: Int32

    public init(code: Int32) { self.code = code }

    public var observation: String {
        switch code {
        case ENOENT, ECONNREFUSED: return "absent"
        case EPERM, EACCES: return "permissionDenied"
        case ENAMETOOLONG, EINVAL: return "unknown"
        default: return "unreachable"
        }
    }

    public var description: String { "\(String(cString: strerror(code))) (errno \(code))" }

    public func action(socket: String) -> String {
        if observation == "permissionDenied" {
            return
                "allow the active harness sandbox to connect to the exact Unix socket \(socket), then retry; a run wrapper cannot grant permission"
        }
        return
            "check the endpoint and daemon log from a permitted terminal; start the daemon there if no listener exists"
    }
}

/// Observed values only. Missing values never inherit scheduler fallbacks.
public struct MemoryObservation: Codable, Equatable, Sendable {
    public var source: String
    public var sampledAt: Double?
    public var level: Int?
    public var physical: UInt64?
    public var kernelPressure: Int?
    public var swapUsed: UInt64?
    public var errors: [String: String]
    public var effectivePressure: String?

    public init(
        source: String, sampledAt: Double?, level: Int?, physical: UInt64?, kernelPressure: Int?, swapUsed: UInt64?,
        errors: [String: String] = [:]
    ) {
        self.source = source
        self.sampledAt = sampledAt
        self.level = level
        self.physical = physical
        self.kernelPressure = kernelPressure
        self.swapUsed = swapUsed
        self.errors = errors
    }

    public var complete: Bool {
        level != nil && physical != nil && kernelPressure != nil && swapUsed != nil && errors.isEmpty
    }

    public var summary: String {
        var values: [String] = []
        if !complete { values.append("unknown (incomplete observation)") }
        values.append(level.map { "\($0)% free" } ?? "free level unknown")
        values.append(physical.map { "of \(Bytes.format($0))" } ?? "physical memory unknown")
        values.append(kernelPressure.map { "pressure \(MemoryPressure(level: Int64($0)).name)" } ?? "pressure unknown")
        values.append(swapUsed.map { "swap \(Bytes.format($0)) used" } ?? "swap unknown")
        if let effectivePressure { values.append("effective pressure \(effectivePressure)") }
        values.append("source \(source), " + (sampledAt.map { "sampled at \($0)" } ?? "sample time unknown"))
        values += errors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return values.joined(separator: ", ")
    }

    /// Compatibility policy for scheduling, deliberately separate from diagnostic evidence.
    public func schedulingSample(at: Double) -> MemorySample {
        MemorySample(level: level ?? 100, kernelPressure: kernelPressure ?? 1, swapUsed: swapUsed ?? 0, at: at)
    }
}

extension SystemMemory {
    public static func observation(
        environment: [String: String] = ProcessInfo.processInfo.environment, source: String = "local",
        at: Double = Date().timeIntervalSince1970
    ) -> MemoryObservation {
        var errors: [String: String] = [:]
        func integer(_ name: String, override: String? = nil) -> Int64? {
            if let override, environment[override] != nil {
                guard let value = faked(override, environment) else {
                    errors[name] = "unreadable or invalid override \(override)"
                    return nil
                }
                return value
            }
            guard let value = sysctlInt(name) else {
                let code = errno
                errors[name] = ConnectionFailure(code: code).description
                return nil
            }
            return value
        }
        let rawLevel = integer("kern.memorystatus_level", override: "TURNSTILE_MEMORY_LEVEL_FILE")
        let level = rawLevel.flatMap { (0...100).contains($0) ? Int($0) : nil }
        if rawLevel != nil && level == nil { errors["kern.memorystatus_level"] = "invalid free level" }
        let rawPressure = integer("kern.memorystatus_vm_pressure_level", override: "TURNSTILE_PRESSURE_LEVEL_FILE")
        // Existing deterministic fixtures use zero for normal.
        let pressure = rawPressure.flatMap { [0, 1, 2, 4].contains($0) ? Int(max(1, $0)) : nil }
        if rawPressure != nil && pressure == nil {
            errors["kern.memorystatus_vm_pressure_level"] = "unknown pressure level"
        }
        let physical = integer("hw.memsize").flatMap { $0 > 0 ? UInt64($0) : nil }
        var swap: UInt64?
        if environment["TURNSTILE_SWAP_USED_FILE"] != nil {
            swap = integer("vm.swapusage", override: "TURNSTILE_SWAP_USED_FILE").flatMap { $0 >= 0 ? UInt64($0) : nil }
        } else {
            var usage = xsw_usage()
            var size = MemoryLayout<xsw_usage>.size
            if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 {
                swap = usage.xsu_used
            } else {
                errors["vm.swapusage"] = ConnectionFailure(code: errno).description
            }
        }
        return MemoryObservation(
            source: source, sampledAt: at, level: level, physical: physical, kernelPressure: pressure,
            swapUsed: swap, errors: errors)
    }
}

/// One live socket query, shared by status and doctor. Never reads disk snapshots or starts a daemon.
public enum DaemonObservation {
    case reachable(StatusSnapshot)
    case failed(state: String, code: Int32?, error: String)

    public static func read(socket: String) -> Self {
        switch Client.connecting(socketPath: socket) {
        case .failure(let failure):
            return .failed(state: failure.observation, code: failure.code, error: failure.description)
        case .success(let client):
            guard let reply = client.roundTrip(Message(type: "status")), let snapshot = reply.status else {
                return .failed(
                    state: "unreachable", code: nil, error: "connected, but no valid status reply within 5 seconds")
            }
            return .reachable(snapshot)
        }
    }

    public func action(socket: String) -> String {
        if case .failed(_, let code?, _) = self { return ConnectionFailure(code: code).action(socket: socket) }
        return "check the daemon log from a permitted terminal and retry the status query"
    }

    public func text(socket: String) -> String {
        switch self {
        case .reachable(let snapshot):
            return "pid \(snapshot.daemonPid), \(snapshot.running.count) running, \(snapshot.queued.count) queued"
        case .failed(let state, _, let error):
            let label = state == "permissionDenied" ? "permission denied; daemon presence unknown" : state
            return "daemon observation \(label) at \(socket): \(error)"
        }
    }
}
