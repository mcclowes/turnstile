import TurnstileCore

/// Monotonic timing reports; observes stalls without changing scheduler policy.
struct TickDiagnostics: Sendable {
    static let slowTickThreshold = 5.0
    static let longGapThreshold = 30.0

    private var lastFinished: Double?
    private var started = 0.0
    private var checkpoint = 0.0
    private var slowest: (name: String, seconds: Double)?

    mutating func begin(at now: Double) -> String? {
        started = now
        checkpoint = now
        slowest = nil
        guard let lastFinished, now - lastFinished >= Self.longGapThreshold else { return nil }
        return "daemon scheduler had a \(formatDuration(now - lastFinished)) gap between ticks"
    }

    mutating func completePhase(_ name: String, at now: Double) {
        let seconds = now - checkpoint
        if slowest == nil || seconds > slowest!.seconds {
            slowest = (name, seconds)
        }
        checkpoint = now
    }

    mutating func finish(at now: Double) -> String? {
        lastFinished = now
        let seconds = now - started
        guard seconds >= Self.slowTickThreshold else { return nil }
        var message = "daemon tick took \(formatDuration(seconds))"
        if let slowest {
            message += "; slowest phase: \(slowest.name) (\(formatDuration(slowest.seconds)))"
        }
        return message
    }
}
