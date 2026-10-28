import Darwin
import Foundation

/// One app's memory in a single sample: every process in its bundle, helpers included.
public struct AppFootprint: Codable, Equatable, Sendable {
    public var app: String
    public var bytes: UInt64

    public init(app: String, bytes: UInt64) {
        self.app = app
        self.bytes = bytes
    }
}

/// What an app usually held across the samples in a window.
public struct AppUsage: Codable, Equatable, Sendable {
    public var app: String
    /// Mean over every sample, counting the ones it was missing from as zero, so it reads as a baseline.
    public var average: UInt64
    public var peak: UInt64
    /// Fraction of samples it appeared in.
    public var presence: Double

    public init(app: String, average: UInt64, peak: UInt64, presence: Double) {
        self.app = app
        self.average = average
        self.peak = peak
        self.presence = presence
    }
}

public struct AppMemoryReport: Codable, Equatable, Sendable {
    public var days: Int
    public var samples: Int
    /// Mean of everything readable outside turnstile's jobs, long tail included.
    public var averageTotal: UInt64
    public var physical: UInt64
    public var apps: [AppUsage]
    public var more: Int

    public init(days: Int, samples: Int, averageTotal: UInt64, physical: UInt64, apps: [AppUsage], more: Int) {
        self.days = days
        self.samples = samples
        self.averageTotal = averageTotal
        self.physical = physical
        self.apps = apps
        self.more = more
    }
}

/// Which apps hold memory outside turnstile's jobs, sampled while the daemon runs. A single reading
/// says little, since what's open changes through the day, so the report is built from many.
public enum AppMemory {
    public static let interval: Double = 60
    /// Apps kept per sample; the long tail is dropped rather than stored.
    public static let kept = 15
    public static let floor = 50 * Bytes.mb

    /// System services that host other apps' work, named for what the user would recognise.
    static let aliases = [
        "com.apple.Virtualization.VirtualMachine": "Virtual machines",
        "com.apple.WebKit.WebContent": "Safari and web views",
    ]

    /// The outermost `.app` in the path, so helpers count toward their app; otherwise the executable's name.
    public static func app(forExecutable path: String) -> String {
        let parts = path.split(separator: "/")
        if let bundle = parts.first(where: { $0.hasSuffix(".app") }) {
            return String(bundle.dropLast(4))
        }
        let name = parts.last.map(String.init) ?? path
        return aliases[name] ?? name
    }

    public static func top(_ processes: [(executable: String, bytes: UInt64)], limit: Int, floor: UInt64)
        -> [AppFootprint]
    {
        var totals: [String: UInt64] = [:]
        for process in processes { totals[app(forExecutable: process.executable), default: 0] += process.bytes }
        return totals.filter { $0.value >= floor }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { AppFootprint(app: $0.key, bytes: $0.value) }
    }

    /// Every process this user can read, minus `excluded`. Root and other users' processes can't be read without root.
    public static func snapshot(excluding excluded: Set<pid_t>) -> (total: UInt64, apps: [AppFootprint]) {
        var processes: [(executable: String, bytes: UInt64)] = []
        for pid in ProcessTree.allPids() where !excluded.contains(pid) {
            guard let bytes = ProcessTree.footprint(pid), let path = ProcessTree.executable(pid) else { continue }
            processes.append((path, bytes))
        }
        let total = processes.reduce(0) { $0 + $1.bytes }
        return (total, top(processes, limit: kept, floor: floor))
    }
}

public enum AppMemoryFormatter {
    public static func render(_ report: AppMemoryReport) -> String {
        guard report.samples > 0 else {
            return
                "apps: no samples in the last \(report.days) days. turnstile samples app memory while its daemon runs."
        }
        let covered = formatDuration(Double(report.samples) * AppMemory.interval)
        var lines = [
            "apps: sampled every minute while turnstile ran, \(covered) over the last \(report.days) days", "",
        ]
        var rows = [["app", "average", "peak", "present"]]
        for app in report.apps {
            rows.append([
                app.app, Bytes.format(app.average), Bytes.format(app.peak), "\(Int((app.presence * 100).rounded()))%",
            ])
        }
        lines += TextTable.render(rows, alignRight: [false, true, true, true])
        if report.more > 0 { lines.append("  and \(report.more) more") }
        lines.append("")
        // Footprints include compressed and swapped pages, so a share of physical memory would mislead.
        lines.append(
            "Everything outside turnstile's jobs averaged \(Bytes.format(report.averageTotal)). Like Activity Monitor, that counts"
        )
        lines.append(
            "compressed and swapped memory, so it can add up to more than this Mac's \(Bytes.format(report.physical)).")
        return lines.joined(separator: "\n")
    }
}
