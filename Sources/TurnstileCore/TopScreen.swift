import Foundation

/// The model behind `turnstile top`: which job is selected, what a key does to it, and what the screen shows.
/// Kept free of terminal I/O so it can be tested.
public enum TopScreen {
    public enum Key: Equatable, Sendable {
        case up, down, bump, pause, hold, kill, quit, yes, no, other
    }

    public static func key(_ byte: UInt8) -> Key {
        switch byte {
        case UInt8(ascii: "k"): return .up
        case UInt8(ascii: "j"): return .down
        case UInt8(ascii: "b"): return .bump
        case UInt8(ascii: "p"): return .pause
        case UInt8(ascii: "h"): return .hold
        case UInt8(ascii: "x"): return .kill
        case UInt8(ascii: "q"), 0x03, 0x04: return .quit
        case UInt8(ascii: "y"), UInt8(ascii: "Y"): return .yes
        case UInt8(ascii: "n"), UInt8(ascii: "N"), 0x1B: return .no
        default: return .other
        }
    }

    /// Keys from one read of stdin, with arrow-key escape sequences folded in.
    public static func keys(_ bytes: [UInt8]) -> [Key] {
        var result: [Key] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x1B, index + 2 < bytes.count, bytes[index + 1] == UInt8(ascii: "[") || bytes[index + 1] == UInt8(ascii: "O") {
                switch bytes[index + 2] {
                case UInt8(ascii: "A"): result.append(.up)
                case UInt8(ascii: "B"): result.append(.down)
                default: result.append(.other)
                }
                index += 3
                continue
            }
            result.append(key(bytes[index]))
            index += 1
        }
        return result
    }

    public static func rows(_ snapshot: StatusSnapshot?) -> [JobSnapshot] {
        guard let snapshot else { return [] }
        return snapshot.running + snapshot.queued
    }

    /// Keeps the selection on the same job across refreshes, falling back to the first.
    public static func settle(_ selected: Int64?, in rows: [JobSnapshot]) -> Int64? {
        if let selected, rows.contains(where: { $0.id == selected }) { return selected }
        return rows.first?.id
    }

    public static func move(_ selected: Int64?, by delta: Int, in rows: [JobSnapshot]) -> Int64? {
        guard !rows.isEmpty else { return nil }
        let current = rows.firstIndex { $0.id == selected } ?? 0
        return rows[max(0, min(rows.count - 1, current + delta))].id
    }

    /// The control message a key sends for a job, or why it doesn't apply.
    public static func control(for key: Key, job: JobSnapshot) -> Result<String, ControlProblem> {
        let queued = job.state == "queued"
        switch key {
        case .bump: return .success("bump")
        case .kill: return .success("kill")
        case .pause:
            if queued { return .failure(ControlProblem("#\(job.id) hasn't started; h holds it in the queue")) }
            return .success(job.paused ? "resume" : "pause")
        case .hold:
            if !queued { return .failure(ControlProblem("#\(job.id) is already running; p pauses it")) }
            return .success(job.held == true ? "unhold" : "hold")
        default:
            return .failure(ControlProblem(""))
        }
    }

    public struct ControlProblem: Error, Equatable {
        public let text: String
        public init(_ text: String) { self.text = text }
    }

    public static let help = "↑↓/jk select · b bump · p pause/resume · h hold/release · x kill · q quit"

    public static func render(_ snapshot: StatusSnapshot?, selected: Int64?, now: Double, width: Int, height: Int, footer: String) -> [String] {
        var lines: [String] = []
        guard let snapshot else {
            lines.append("turnstile top · daemon idle (starts with the first gated command)")
            lines.append("")
            lines.append("Nothing is running or queued. This screen picks the daemon up when it starts.")
            return fit(lines, footer: footer, width: width, height: height)
        }
        let free = snapshot.physicalMemory / 100 * UInt64(snapshot.memoryLevel)
        let slots = ResourceClass.allCases.map { "\($0.rawValue) \(snapshot.limits[$0.rawValue] ?? 1)" }.joined(separator: ", ")
        lines.append("turnstile top · memory \(snapshot.memoryLevel)% free (~\(Bytes.format(free)) of \(Bytes.format(snapshot.physicalMemory))) · slots \(slots)")
        lines.append("")

        let jobs = rows(snapshot)
        if jobs.isEmpty {
            lines.append("  nothing running or queued")
        } else {
            lines.append("  " + columns(["#", "STATE", "CLASS", "MEMORY", "TIME", "JOB"]))
            for job in jobs {
                let marker = job.id == selected ? "▸ " : "  "
                let line = marker + columns(cells(job, now: now))
                lines.append(job.id == selected ? "\u{1B}[7m" + line + "\u{1B}[0m" : line)
            }
            if let job = jobs.first(where: { $0.id == selected }), job.state == "queued", let reason = job.waiting {
                lines.append("")
                lines.append("  #\(job.id) \(reason)")
            }
        }

        if !snapshot.recent.isEmpty {
            lines.append("")
            lines.append("recent:")
            for entry in snapshot.recent {
                var detail = entry.outcome
                if let peak = entry.peak { detail += ", peak \(Bytes.format(peak))" }
                if let duration = entry.duration { detail += ", \(formatDuration(duration))" }
                lines.append("  #\(entry.id)  \(entry.project) \(entry.key)  \(detail)")
            }
        }
        if let report = Escapes.report(snapshot.ungated, home: homeDirectory(ProcessInfo.processInfo.environment)) {
            lines.append("")
            lines.append("outside turnstile (last hour): \(report)")
        }
        return fit(lines, footer: footer, width: width, height: height)
    }

    static let widths = [6, 16, 8, 20, 12]

    static func columns(_ cells: [String]) -> String {
        var line = ""
        for (index, cell) in cells.enumerated() {
            line += index < widths.count ? cell.padding(toLength: max(widths[index], cell.count + 1), withPad: " ", startingAt: 0) : cell
        }
        return line
    }

    static func cells(_ job: JobSnapshot, now: Double) -> [String] {
        var state = job.state
        if job.paused { state = job.pausedBy == "you" ? "paused (you)" : "paused (mem)" }
        if job.held == true { state = "held" }
        let memory: String
        let time: String
        if job.state == "queued" {
            memory = "~\(Bytes.format(job.estimate))"
            time = "waiting \(formatDuration(now - job.queuedAt))"
        } else {
            memory = "\(Bytes.format(job.footprint ?? 0)) / ~\(Bytes.format(job.estimate))"
            time = job.startedAt.map { formatDuration(now - $0) } ?? "-"
        }
        var name = job.label
        if job.agent { name += "  [agent]" }
        if job.joiners > 0 { name += "  [+\(job.joiners) joined]" }
        return ["\(job.id)", state, job.resourceClass.rawValue, memory, time, name]
    }

    /// Clips to the terminal, keeping the help and footer lines at the bottom.
    static func fit(_ body: [String], footer: String, width: Int, height: Int) -> [String] {
        let bottom = [help, footer]
        let room = max(0, height - bottom.count - 1)
        var lines = Array(body.prefix(room))
        while lines.count < room { lines.append("") }
        lines.append("")
        lines += bottom
        return lines.map { clip($0, to: width) }
    }

    /// Truncates to `width` visible characters, leaving escape sequences intact.
    static func clip(_ line: String, to width: Int) -> String {
        var visible = 0
        var result = ""
        var inEscape = false
        for character in line {
            if character == "\u{1B}" { inEscape = true }
            if inEscape {
                result.append(character)
                if character.isLetter { inEscape = false }
                continue
            }
            guard visible < width else { continue }
            result.append(character)
            visible += 1
        }
        return result
    }
}
