import Foundation

/// What the menu bar app shows and notifies about, derived from successive status snapshots.
public enum MenuBarState {
    public static let idleSymbol = "square.stack.3d.up.slash"
    public static let busySymbol = "square.stack.3d.up"
    public static let pausedSymbol = "pause.circle"
    public static let pressureSymbol = "exclamationmark.triangle"
    /// Below this, the icon warns even if nothing has been paused yet.
    public static let lowMemoryPercent = 15

    public struct Indicator: Equatable, Sendable {
        public var symbol: String
        /// Queued jobs, when there are any.
        public var count: Int?

        public init(symbol: String, count: Int?) {
            self.symbol = symbol
            self.count = count
        }
    }

    public static func indicator(_ snapshot: StatusSnapshot?) -> Indicator {
        guard let snapshot else { return Indicator(symbol: idleSymbol, count: nil) }
        let count = snapshot.queued.isEmpty ? nil : snapshot.queued.count
        let symbol: String
        if snapshot.memoryLevel < lowMemoryPercent || snapshot.running.contains(where: { $0.pausedBy == "memory" }) {
            symbol = pressureSymbol
        } else if snapshot.running.contains(where: \.paused) {
            symbol = pausedSymbol
        } else {
            symbol = busySymbol
        }
        return Indicator(symbol: symbol, count: count)
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
