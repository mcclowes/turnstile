import Foundation

/// What the menu bar app shows and notifies about, derived from successive status snapshots.
public enum MenuBarState {
    public static let idleSymbol = "square.stack.3d.up.slash"
    public static let busySymbol = "square.stack.3d.up"
    public static let pausedSymbol = "pause.circle"
    public static let pressureSymbol = "exclamationmark.triangle"
    /// Below this, the icon warns even if nothing has been paused yet.
    public static let lowMemoryPercent = 15
    /// Below this, memory is worth watching but nothing is wrong yet.
    public static let tightMemoryPercent = 30

    /// How much attention a piece of the menu asks for. The app turns these into colours.
    public enum Tone: String, Equatable, Sendable {
        case neutral, good, warning, danger
    }

    /// A symbol and the tone to draw it in.
    public struct Badge: Equatable, Sendable {
        public var symbol: String
        public var tone: Tone

        public init(_ symbol: String, _ tone: Tone) {
            self.symbol = symbol
            self.tone = tone
        }
    }

    public struct Indicator: Equatable, Sendable {
        public var symbol: String
        /// Queued jobs, when there are any.
        public var count: Int?
        /// Only coloured when something wants you to look.
        public var tone: Tone

        public init(symbol: String, count: Int?, tone: Tone = .neutral) {
            self.symbol = symbol
            self.count = count
            self.tone = tone
        }
    }

    public static func indicator(_ snapshot: StatusSnapshot?) -> Indicator {
        guard let snapshot else { return Indicator(symbol: idleSymbol, count: nil) }
        let count = snapshot.queued.isEmpty ? nil : snapshot.queued.count
        if snapshot.memoryLevel < lowMemoryPercent || snapshot.running.contains(where: { $0.pausedBy == "memory" }) {
            return Indicator(symbol: pressureSymbol, count: count, tone: .danger)
        }
        if snapshot.running.contains(where: \.paused) {
            return Indicator(symbol: pausedSymbol, count: count, tone: .warning)
        }
        return Indicator(symbol: busySymbol, count: count, tone: .neutral)
    }

    public static func memoryTone(_ level: Int) -> Tone {
        if level < lowMemoryPercent { return .danger }
        if level < tightMemoryPercent { return .warning }
        return .good
    }

    public static func symbol(for resourceClass: ResourceClass) -> String {
        switch resourceClass {
        case .compile: return "hammer.fill"
        case .test: return "checkmark.seal.fill"
        case .browser: return "globe"
        }
    }

    /// The dot beside a job: what it's doing, and whether that's fine.
    public static func badge(for job: JobSnapshot) -> Badge {
        if job.held == true { return Badge("hand.raised.fill", .warning) }
        if job.paused { return Badge("pause.fill", job.pausedBy == "memory" ? .warning : .neutral) }
        if job.state == "queued" { return Badge("clock.fill", .neutral) }
        return Badge("play.fill", .good)
    }

    /// A job's state in a word or two.
    public static func stateText(for job: JobSnapshot) -> String {
        if job.held == true { return "Held" }
        if job.paused { return job.pausedBy == "memory" ? "Paused for memory" : "Paused" }
        return job.state == "queued" ? "Queued" : "Running"
    }

    /// "579 MB of ~2 GB" once it's running, "~2 GB expected" while it waits.
    public static func memoryText(for job: JobSnapshot) -> String {
        job.state == "queued"
            ? "~\(Bytes.format(job.estimate)) expected"
            : "\(Bytes.format(job.footprint ?? 0)) of ~\(Bytes.format(job.estimate))"
    }

    /// How much of its estimate a running job is using, clamped to 0...1. Nil while it's queued.
    public static func memoryFraction(for job: JobSnapshot) -> Double? {
        guard job.state != "queued", job.estimate > 0 else { return nil }
        return min(1, Double(job.footprint ?? 0) / Double(job.estimate))
    }

    /// Over its estimate is worth a look; well over is where the runaway killer lives.
    public static func footprintTone(for job: JobSnapshot) -> Tone {
        guard let fraction = memoryFraction(for: job) else { return .neutral }
        if fraction >= 1 { return .warning }
        return .good
    }

    public static func badge(for entry: HistoryEntry) -> Badge {
        switch entry.outcome {
        case "ok": return Badge("checkmark.circle.fill", .good)
        case "killed": return Badge("bolt.circle.fill", .danger)
        case "failed", "signaled": return Badge("xmark.circle.fill", .danger)
        case "lost": return Badge("questionmark.circle.fill", .warning)
        case "joined", "superseded": return Badge("arrow.triangle.merge", .neutral)
        default: return Badge("minus.circle.fill", .neutral)
        }
    }

    /// "failed (1) · 2m04s · peak 7 GB".
    public static func detail(for entry: HistoryEntry) -> String {
        var parts = [entry.outcome]
        if let code = entry.exitCode, entry.outcome == "failed" { parts[0] += " (\(code))" }
        if let duration = entry.duration { parts.append(formatDuration(duration)) }
        if let peak = entry.peak { parts.append("peak \(Bytes.format(peak))") }
        return parts.joined(separator: " · ")
    }

    public static func symbol(for action: Action) -> String {
        switch action.message {
        case "bump": return "arrow.up.to.line"
        case "hold": return "hand.raised.fill"
        case "unhold": return "hand.raised.slash.fill"
        case "pause": return "pause.fill"
        case "resume": return "play.fill"
        default: return "xmark"
        }
    }

    public struct Action: Equatable, Sendable {
        public var title: String
        /// The control message to send, with the job as its target.
        public var message: String
    }

    public static func actions(for job: JobSnapshot) -> [Action] {
        let bump = Action(title: job.state == "queued" ? "Move to front" : "Raise priority", message: "bump")
        let kill = Action(title: "Kill", message: "kill")
        if job.state == "queued" {
            return [bump, job.held == true ? Action(title: "Release", message: "unhold") : Action(title: "Hold", message: "hold"), kill]
        }
        return [bump, job.paused ? Action(title: "Resume", message: "resume") : Action(title: "Pause", message: "pause"), kill]
    }

    public struct Event: Equatable, Sendable {
        public var title: String
        public var body: String
    }

    /// Jobs newly paused for memory, and runs newly killed as runaways. Nothing on the first snapshot, so launching doesn't replay history.
    public static func events(from old: StatusSnapshot?, to new: StatusSnapshot?) -> [Event] {
        guard let old, let new else { return [] }
        var events: [Event] = []
        let alreadyPaused = Set(old.running.filter { $0.pausedBy == "memory" }.map(\.id))
        for job in new.running where job.pausedBy == "memory" && !alreadyPaused.contains(job.id) {
            events.append(Event(title: "Paused #\(job.id) \(job.label)", body: "Memory is low (\(new.memoryLevel)% free). It resumes when memory recovers."))
        }
        let newest = old.recent.map(\.id).max() ?? 0
        for entry in new.recent where entry.id > newest && entry.outcome == "killed" {
            let peak = entry.peak.map { " at \(Bytes.format($0))" } ?? ""
            events.append(Event(title: "Killed #\(entry.id) \(entry.project) \(entry.key)", body: "It used far more memory than usual\(peak)."))
        }
        return events
    }
}
