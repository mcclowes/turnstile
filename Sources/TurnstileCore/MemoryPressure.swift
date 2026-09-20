import Foundation

/// One reading of the machine's memory signals.
public struct MemorySample: Equatable, Sendable {
    /// Percent the kernel considers available (`kern.memorystatus_level`).
    public var level: Int
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warn, 4 critical.
    public var kernelPressure: Int
    /// Bytes of swap in use (`vm.swapusage`).
    public var swapUsed: UInt64
    /// Monotonic seconds.
    public var at: Double

    public init(level: Int, kernelPressure: Int = 1, swapUsed: UInt64 = 0, at: Double) {
        self.level = level
        self.kernelPressure = kernelPressure
        self.swapUsed = swapUsed
        self.at = at
    }
}

/// How much room the machine really has, beyond what the free-memory level admits to.
public enum EffectiveMemoryPressure: Int, Comparable, Sendable {
    /// The level means what it says.
    case normal = 0
    /// Swap is growing, so the level is measuring the stand-off, not room for new work.
    case swapping = 1
    /// The kernel says critical, or swap is growing fast enough that jobs are losing the race.
    case critical = 2

    public static func < (a: EffectiveMemoryPressure, b: EffectiveMemoryPressure) -> Bool { a.rawValue < b.rawValue }
}

/// Reads pressure from a stream of samples.
///
/// The signal is swap *growth*, not how much swap is in use: a machine can sit on 7 GB of cold swap
/// with room to spare, and `kern.memorystatus_vm_pressure_level` reads "warn" there all day, so
/// neither is worth gating on. Growth means the kernel is pushing pages out right now to hold the
/// free-memory level up, which is exactly when that level stops describing room for a new job.
public struct MemoryPressureTracker: Sendable {
    /// Growth is measured over this many seconds.
    public static let window: Double = 20
    /// Swap has to grow by this much within the window to count. Below that it's ordinary churn.
    public static let growth: UInt64 = 256 * Bytes.mb
    /// Four times that in the same window: the machine is falling behind, not just paging.
    public static let fastGrowth: UInt64 = 4 * growth

    private var samples: [MemorySample] = []

    public init() {}

    public mutating func record(_ sample: MemorySample) {
        samples.append(sample)
        samples.removeAll { sample.at - $0.at > Self.window }
    }

    public var latest: MemorySample? { samples.last }

    public var pressure: EffectiveMemoryPressure {
        guard let newest = samples.last else { return .normal }
        if newest.kernelPressure >= 4 { return .critical }
        guard let oldest = samples.first, newest.swapUsed > oldest.swapUsed else { return .normal }
        let grew = newest.swapUsed - oldest.swapUsed
        if grew >= Self.fastGrowth { return .critical }
        if grew >= Self.growth { return .swapping }
        return .normal
    }
}
