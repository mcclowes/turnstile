import Foundation

/// The machine limits the Settings window edits. Nil means the built-in default; the rest stays JSON-only.
public struct LimitSettings: Equatable, Sendable {
    public var concurrency: [ResourceClass: Int] = [:]
    public var reserve: UInt64?
    public var pause = true
    public var inject = true
    public var killMultiplier: Double?
    public var maxMemory: UInt64?

    public init() {}

    /// Reads the global file only: a project's `.turnstilerc` can override throttling, but this window doesn't edit it.
    public init(file: ConfigFile) {
        for cls in ResourceClass.allCases {
            concurrency[cls] = file.machine.concurrency?[cls.rawValue]
        }
        reserve = file.machine.reserve
        pause = file.throttle?.pause ?? true
        inject = file.throttle?.inject ?? true
        killMultiplier = file.throttle?.killMultiplier
        maxMemory = file.throttle?.maxMemory
    }

    public func slots(for cls: ResourceClass) -> Int {
        concurrency[cls].map { max(1, $0) } ?? MachineConfig().concurrencyLimit(for: cls)
    }

    public var reserveBytes: UInt64 { reserve ?? MachineConfig().reserveBytes }
    public var killMultiplierValue: Double { killMultiplier ?? Pressure.defaultKillMultiplier }

    /// Writes only the keys that differ from what `data` already says, so hand-written values keep their spelling.
    public func updatingConfig(_ data: Data) throws -> Data {
        let current = LimitSettings(file: try ConfigFile.decode(data))
        return try ConfigJSON.edit(data) { root in
            for cls in ResourceClass.allCases where concurrency[cls] != current.concurrency[cls] {
                root.set(concurrency[cls], forKey: cls.rawValue, in: "concurrency")
            }
            if reserve != current.reserve { root["reserve"] = reserve.map(Bytes.format) }
            if pause != current.pause { root.set(pause ? nil : false, forKey: "pause", in: "throttle") }
            if inject != current.inject { root.set(inject ? nil : false, forKey: "inject", in: "throttle") }
            if killMultiplier != current.killMultiplier { root.set(killMultiplier, forKey: "killMultiplier", in: "throttle") }
            if maxMemory != current.maxMemory { root.set(maxMemory.map(Bytes.format), forKey: "maxMemory", in: "throttle") }
        }
    }
}
