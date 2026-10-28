import Foundation

/// Lines that `turnstile status` and `turnstile top` both show, so the two read the same.
extension StatusSnapshot {
    /// "40% free (~6.4 GB of 16 GB)".
    public var memorySummary: String {
        let free = SystemMemory.free(level: memoryLevel, of: physicalMemory)
        return "\(memoryLevel)% free (~\(Bytes.format(free)) of \(Bytes.format(physicalMemory)))"
    }

    /// "compile 2, test 1, browser 1".
    public var slotsSummary: String {
        ResourceClass.allCases.map { "\($0.rawValue) \(limits[$0.rawValue] ?? 1)" }.joined(separator: ", ")
    }
}

extension HistoryEntry {
    /// "#4  api swift test  failed (2), peak 1.2 GB, 5s".
    public var summary: String {
        var detail = outcome
        if let exitCode, outcome == "failed" { detail += " (\(exitCode))" }
        if let peak { detail += ", peak \(Bytes.format(peak))" }
        if let duration { detail += ", \(formatDuration(duration))" }
        return "#\(id)  \(project) \(key)  \(detail)"
    }
}
