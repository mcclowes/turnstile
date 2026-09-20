import Foundation

/// One finished job, as the history summary reads it.
public struct HistoryRow: Equatable, Sendable {
    public var root: String
    public var key: String
    public var agent: Bool
    public var outcome: String
    public var peak: UInt64?
    public var duration: Double?
    public var wait: Double?

    public init(root: String, key: String, agent: Bool, outcome: String, peak: UInt64?, duration: Double?, wait: Double?) {
        self.root = root
        self.key = key
        self.agent = agent
        self.outcome = outcome
        self.peak = peak
        self.duration = duration
        self.wait = wait
    }
}

/// What turnstile has learned about one command in one project.
public struct CommandSummary: Codable, Equatable, Sendable {
    public var project: String
    public var key: String
    public var runs: Int
    public var medianPeak: UInt64?
    public var maxPeak: UInt64?
    public var medianDuration: Double?

    public init(project: String, key: String, runs: Int, medianPeak: UInt64?, maxPeak: UInt64?, medianDuration: Double?) {
        self.project = project
        self.key = key
        self.runs = runs
        self.medianPeak = medianPeak
        self.maxPeak = maxPeak
        self.medianDuration = medianDuration
    }
}

/// How long jobs sat in the queue before they started.
public struct WaitSummary: Codable, Equatable, Sendable {
    public var started: Int
    public var median: Double
    public var p90: Double
    public var longest: Double
    /// Waits past two minutes, which is where an agent harness starts timing runs out.
    public var overTwoMinutes: Int

    public init(started: Int, median: Double, p90: Double, longest: Double, overTwoMinutes: Int) {
        self.started = started
        self.median = median
        self.p90 = p90
        self.longest = longest
        self.overTwoMinutes = overTwoMinutes
    }
}

public struct HistorySummary: Codable, Equatable, Sendable {
    public var days: Int
    public var jobs: Int
    public var projects: Int
    public var agentJobs: Int
    public var outcomes: [String: Int]
    public var waits: WaitSummary?
    public var commands: [CommandSummary]
    /// Commands left out by the limit.
    public var more: Int

    public init(days: Int, jobs: Int, projects: Int, agentJobs: Int, outcomes: [String: Int], waits: WaitSummary?, commands: [CommandSummary], more: Int) {
        self.days = days
        self.jobs = jobs
        self.projects = projects
        self.agentJobs = agentJobs
        self.outcomes = outcomes
        self.waits = waits
        self.commands = commands
        self.more = more
    }

    /// Groups by project and command, the same pair the scheduler estimates from, so the numbers here
    /// are the ones it works off. Ordered by the memory a command needs, since that's what holds a queue up.
    public static func summarize(_ rows: [HistoryRow], days: Int, limit: Int) -> HistorySummary {
        var outcomes: [String: Int] = [:]
        var grouped: [String: [HistoryRow]] = [:]
        var waits: [Double] = []
        var roots: Set<String> = []
        for row in rows {
            outcomes[row.outcome, default: 0] += 1
            roots.insert(row.root)
            if let wait = row.wait { waits.append(wait) }
            // A run that merged into another never ran on its own, so it has nothing to say about cost.
            guard row.outcome != "joined" && row.outcome != "superseded" else { continue }
            grouped[row.root + "\u{0}" + row.key, default: []].append(row)
        }

        var commands = grouped.values.map { group -> CommandSummary in
            let peaks = group.compactMap(\.peak).filter { $0 > 0 }
            let durations = group.compactMap(\.duration).filter { $0 > 0 }
            return CommandSummary(
                project: projectName(group[0].root),
                key: group[0].key,
                runs: group.count,
                medianPeak: median(peaks.map(Double.init)).map { UInt64($0) },
                maxPeak: peaks.max(),
                medianDuration: median(durations)
            )
        }
        commands.sort {
            ($0.maxPeak ?? 0, $0.runs, $1.project) > ($1.maxPeak ?? 0, $1.runs, $0.project)
        }

        return HistorySummary(
            days: days,
            jobs: rows.count,
            projects: roots.count,
            agentJobs: rows.filter(\.agent).count,
            outcomes: outcomes,
            waits: waitSummary(waits),
            commands: Array(commands.prefix(limit)),
            more: max(0, commands.count - limit)
        )
    }

    private static func waitSummary(_ waits: [Double]) -> WaitSummary? {
        guard !waits.isEmpty else { return nil }
        let sorted = waits.sorted()
        return WaitSummary(
            started: sorted.count,
            median: median(sorted) ?? 0,
            p90: sorted[min(sorted.count - 1, Int(0.9 * Double(sorted.count)))],
            longest: sorted[sorted.count - 1],
            overTwoMinutes: sorted.filter { $0 > 120 }.count
        )
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

public enum HistoryFormatter {
    /// Outcomes worth calling out: everything that isn't a run that simply finished.
    static let notable = ["failed", "killed", "signaled", "cancelled", "lost"]

    public static func render(_ summary: HistorySummary, here: String?) -> String {
        let scope = here.map { "in \(projectName($0))" } ?? "in \(summary.projects) project\(summary.projects == 1 ? "" : "s")"
        guard summary.jobs > 0 else {
            return "history: nothing \(scope) in the last \(summary.days) days"
        }
        var lines = ["history: \(summary.jobs) jobs \(scope) over \(summary.days) days, \(summary.agentJobs) from agents"]

        lines.append("")
        lines.append("commands:")
        lines.append(contentsOf: table(summary.commands, showProject: here == nil))
        if summary.more > 0 { lines.append("  and \(summary.more) more") }

        if let waits = summary.waits {
            lines.append("")
            var line = "waits: \(waits.started) started, median \(formatDuration(waits.median))"
            line += ", p90 \(formatDuration(waits.p90)), longest \(formatDuration(waits.longest))"
            if waits.overTwoMinutes > 0 { line += ", \(waits.overTwoMinutes) over 2m" }
            lines.append(line)
        }

        let merged = (summary.outcomes["joined"] ?? 0) + (summary.outcomes["superseded"] ?? 0)
        if merged > 0 {
            lines.append("merged: \(summary.outcomes["joined"] ?? 0) joined a run already going, "
                + "\(summary.outcomes["superseded"] ?? 0) replaced by a newer request")
        }
        let trouble = notable.compactMap { name in summary.outcomes[name].map { "\($0) \(name)" } }
        if !trouble.isEmpty { lines.append("outcomes: \(trouble.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    private static func table(_ commands: [CommandSummary], showProject: Bool) -> [String] {
        guard !commands.isEmpty else { return ["  nothing has run long enough to measure"] }
        var rows = [["project", "command", "runs", "median peak", "max peak", "median time"]]
        for command in commands {
            rows.append([
                command.project,
                command.key,
                "\(command.runs)",
                command.medianPeak.map(Bytes.format) ?? "-",
                command.maxPeak.map(Bytes.format) ?? "-",
                command.medianDuration.map(formatDuration) ?? "-",
            ])
        }
        if !showProject { rows = rows.map { Array($0.dropFirst()) } }
        // Numbers right, names left, so the columns that get compared line up on their last digit.
        let alignRight = Array(repeating: false, count: rows[0].count - 4) + [true, true, true, true]
        let widths = (0..<rows[0].count).map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            "  " + row.enumerated().map { column, cell in
                let padding = String(repeating: " ", count: widths[column] - cell.count)
                return alignRight[column] ? padding + cell : cell + padding
            }.joined(separator: "  ").trimmingTrailingSpaces()
        }
    }
}

extension String {
    func trimmingTrailingSpaces() -> String {
        var text = self
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}
