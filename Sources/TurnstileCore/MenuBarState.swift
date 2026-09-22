import Foundation

/// What the menu bar app shows and notifies about, derived from successive status snapshots.
public enum MenuBarState {
    /// The menu bar icon whether or not the daemon is up; it sleeps when idle, which isn't news.
    public static let iconSymbol = "square.stack.3d.up"
    /// The empty panel's illustration.
    public static let emptySymbol = "square.stack.3d.up.slash"
    public static let pausedSymbol = "pause.circle"
    public static let pressureSymbol = "exclamationmark.triangle"
    public static let disabledSymbol = "shield.slash"
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
        /// Running plus queued jobs, when there are any. Past the slot count, the excess is the queue.
        public var count: Int?
        /// Only coloured when something wants you to look.
        public var tone: Tone

        public init(symbol: String, count: Int?, tone: Tone = .neutral) {
            self.symbol = symbol
            self.count = count
            self.tone = tone
        }
    }

    /// With gating off nothing new is gated, which matters more than anything the daemon says.
    public static func indicator(_ snapshot: StatusSnapshot?, disabled: Bool = false) -> Indicator {
        let inFlight = snapshot.map { $0.running.count + $0.queued.count } ?? 0
        let count = inFlight > 0 ? inFlight : nil
        if disabled { return Indicator(symbol: disabledSymbol, count: count, tone: .danger) }
        guard let snapshot else { return Indicator(symbol: iconSymbol, count: nil) }
        if snapshot.memoryLevel < lowMemoryPercent || snapshot.running.contains(where: { $0.pausedBy == "memory" }) {
            return Indicator(symbol: pressureSymbol, count: count, tone: .danger)
        }
        if snapshot.running.contains(where: \.paused) {
            return Indicator(symbol: pausedSymbol, count: count, tone: .warning)
        }
        return Indicator(symbol: iconSymbol, count: count, tone: .neutral)
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

    public struct Tag: Equatable, Sendable {
        public var text: String
        public var tone: Tone
    }

    /// A job's state, only when its section heading doesn't already say it.
    public static func tag(for job: JobSnapshot) -> Tag? {
        if job.held == true { return Tag(text: "Held", tone: .warning) }
        if job.paused { return job.pausedBy == "memory" ? Tag(text: "Paused for memory", tone: .warning) : Tag(text: "Paused", tone: .neutral) }
        return nil
    }

    /// "25% of ~2 GB" once it's running, "~2 GB expected" while it waits. The share isn't clamped, so a job over its estimate says so.
    public static func memoryText(for job: JobSnapshot) -> String {
        guard job.state != "queued", job.estimate > 0 else { return "~\(Bytes.format(job.estimate)) expected" }
        let percent = Int((Double(job.footprint ?? 0) / Double(job.estimate) * 100).rounded())
        return "\(percent)% of ~\(Bytes.format(job.estimate))"
    }

    /// "52% of 16 GB": the header's one number.
    public static func memoryUsedText(_ snapshot: StatusSnapshot) -> String {
        "\(100 - max(0, min(100, snapshot.memoryLevel)))% of \(Bytes.format(snapshot.physicalMemory))"
    }

    /// How much of its estimate a running job is using, clamped to 0...1. Nil while it's queued.
    public static func memoryFraction(for job: JobSnapshot) -> Double? {
        guard job.state != "queued", job.estimate > 0 else { return nil }
        return min(1, Double(job.footprint ?? 0) / Double(job.estimate))
    }

    /// A full bar reads as "done" unless something says otherwise.
    public static func memoryHelp(for job: JobSnapshot) -> String? {
        guard memoryFraction(for: job) != nil else { return nil }
        return "\(Bytes.format(job.footprint ?? 0)) in use of ~\(Bytes.format(job.estimate)) estimated. The bar fills toward the estimate. It shows memory, not progress."
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

    /// Recent runs shown before the list is expanded.
    public static let recentPreviewCount = 2

    public static func visibleRecent(_ entries: [HistoryEntry], expanded: Bool) -> [HistoryEntry] {
        expanded ? entries : Array(entries.prefix(recentPreviewCount))
    }

    /// Nothing for a run that went fine; the badge already says so.
    public static func outcomeNote(for entry: HistoryEntry) -> String? {
        switch entry.outcome {
        case "ok": return nil
        case "failed": return entry.exitCode.map { "exit \($0)" } ?? "failed"
        default: return entry.outcome
        }
    }

    /// The outcome icon's tooltip, since the icon alone doesn't say what "?" or a bolt means.
    public static func outcomeHelp(for entry: HistoryEntry) -> String {
        let what: String
        switch entry.outcome {
        case "ok": what = "Finished fine"
        case "failed": what = entry.exitCode.map { "Failed with exit code \($0)" } ?? "Failed"
        case "signaled": what = "Stopped by a signal"
        case "killed": what = "Killed by Turnstile or by you"
        case "lost": what = "Lost: whatever started it quit before reporting how it ended, so the result is unknown"
        case "cancelled": what = "Cancelled before it started"
        case "joined": what = "Shared another identical run's result"
        case "superseded": what = "Replaced by a newer identical run"
        default: what = entry.outcome.capitalized
        }
        return entry.log == nil ? what : "\(what). Click to open its output."
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
        /// Hover text: what happens, in a sentence.
        public var help: String
    }

    /// Moving the head of the queue to the front does nothing.
    public static func canPromote(_ job: JobSnapshot, in section: [JobSnapshot]) -> Bool {
        job.state != "queued" || section.first?.id != job.id
    }

    public static func actions(for job: JobSnapshot) -> [Action] {
        let kill = Action(title: "Kill", message: "kill", help: job.state == "queued" ? "Drop #\(job.id) from the queue" : "Stop #\(job.id) and everything it started")
        if job.state == "queued" {
            let bump = Action(title: "Move to front", message: "bump", help: "Start #\(job.id) next, as soon as memory and a slot are free")
            let hold = job.held == true
                ? Action(title: "Release", message: "unhold", help: "Let #\(job.id) start when its turn comes")
                : Action(title: "Hold", message: "hold", help: "Keep #\(job.id) queued until released")
            return [bump, hold, kill]
        }
        let bump = Action(title: "Raise priority", message: "bump", help: "Run #\(job.id) at normal CPU priority, and resume it if paused")
        let toggle = job.paused
            ? Action(title: "Resume", message: "resume", help: "Resume #\(job.id)")
            : Action(title: "Pause", message: "pause", help: "Pause #\(job.id) until you resume it")
        return [bump, toggle, kill]
    }

    /// A wait this long means you've probably walked away, so its end is worth telling you about.
    public static let longWait: Double = 120

    public struct Event: Equatable, Sendable {
        public enum Kind: String, CaseIterable, Sendable {
            case memoryPause, runawayKill, longWait, ownFailure, queueDrained

            /// Menu label for the toggle.
            public var title: String {
                switch self {
                case .memoryPause: return "Paused for memory"
                case .runawayKill: return "Killed as a runaway"
                case .longWait: return "Your job started after a long wait"
                case .ownFailure: return "Your run failed"
                case .queueDrained: return "Queue is clear"
                }
            }

            public var isOnByDefault: Bool { self != .queueDrained }

            /// Only a job stuck on memory is worth breaking Focus for.
            public var urgency: Urgency {
                switch self {
                case .memoryPause: return .timeSensitive
                case .runawayKill, .longWait, .ownFailure: return .active
                case .queueDrained: return .passive
                }
            }

            /// Buttons on the notification, sent as control messages to the event's job.
            public var actions: [Action] {
                guard self == .memoryPause else { return [] }
                return [
                    Action(title: "Resume", message: "resume", help: "Resume it now, whatever memory is doing"),
                    Action(title: "Kill", message: "kill", help: "Stop it and everything it started"),
                ]
            }
        }

        public enum Urgency: Sendable { case passive, active, timeSensitive }

        public var kind: Kind
        public var title: String
        public var body: String
        /// Set only when the job still exists to act on.
        public var job: Int64?
    }

    /// What changed between two polls that someone might want to hear about. Nothing on the first snapshot, so launching doesn't replay history.
    /// Unfiltered: the caller decides which kinds to show.
    public static func events(from old: StatusSnapshot?, to new: StatusSnapshot?) -> [Event] {
        guard let old, let new else { return [] }
        var events: [Event] = []
        let alreadyPaused = Set(old.running.filter { $0.pausedBy == "memory" }.map(\.id))
        for job in new.running where job.pausedBy == "memory" && !alreadyPaused.contains(job.id) {
            events.append(Event(kind: .memoryPause, title: "Paused #\(job.id) \(job.label)", body: "Memory is low (\(new.memoryLevel)% free). It resumes when memory recovers.", job: job.id))
        }
        let wasQueued = Set(old.queued.map(\.id))
        for job in new.running where !job.agent && wasQueued.contains(job.id) {
            guard let startedAt = job.startedAt, startedAt - job.queuedAt >= longWait else { continue }
            events.append(Event(kind: .longWait, title: "Started #\(job.id) \(job.label)", body: "After waiting \(duration(startedAt - job.queuedAt))."))
        }
        let yours = Set((old.running + old.queued).filter { !$0.agent }.map(\.id))
        let newest = old.recent.map(\.id).max() ?? 0
        for entry in new.recent where entry.id > newest {
            let title = "#\(entry.id) \(entry.project) \(entry.key)"
            switch entry.outcome {
            case "killed":
                let peak = entry.peak.map { " at \(Bytes.format($0))" } ?? ""
                events.append(Event(kind: .runawayKill, title: "Killed \(title)", body: "It used far more memory than usual\(peak)."))
            case "failed" where yours.contains(entry.id), "signaled" where yours.contains(entry.id):
                let how = entry.exitCode.map { "It exited with code \($0)." } ?? "It was stopped by a signal."
                events.append(Event(kind: .ownFailure, title: "Failed \(title)", body: how))
            default:
                break
            }
        }
        let wasBusy = !old.running.isEmpty || !old.queued.isEmpty
        if wasBusy && new.running.isEmpty && new.queued.isEmpty {
            events.append(Event(kind: .queueDrained, title: "Queue is clear", body: "Nothing is running or waiting."))
        }
        return events
    }

    private static func duration(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int((seconds / 60).rounded()))m"
    }

    /// The daemon's reason for a wait, with its coarse "starts in" replaced by one that ticks locally.
    public static func waitingText(for job: JobSnapshot, now: Double) -> String? {
        guard let waiting = job.waiting, let startsAt = job.startsAt else { return job.waiting }
        return waiting.replacingOccurrences(of: #", starts in (under a minute|~\d+m)"#, with: ", " + countdown(to: startsAt, now: now), options: .regularExpression)
    }

    /// What a row shows of a wait: the reason and when it ends. The full text belongs in a tooltip.
    public static func waitingHeadline(for job: JobSnapshot, now: Double) -> String? {
        guard let waiting = job.waiting else { return nil }
        let reason = waiting.prefix { $0 != "," && $0 != "(" }.trimmingCharacters(in: .whitespaces)
        let headline = reason.prefix(1).uppercased() + reason.dropFirst()
        guard let startsAt = job.startsAt else { return headline }
        return headline + ", " + countdown(to: startsAt, now: now)
    }

    private static func countdown(to startsAt: Double, now: Double) -> String {
        let remaining = startsAt - now
        return remaining <= 0 ? "should start any moment"
            : remaining < 60 ? "starts in \(Int(remaining.rounded(.up)))s"
            : "starts in ~\(Int((remaining / 60).rounded(.up)))m"
    }
}
