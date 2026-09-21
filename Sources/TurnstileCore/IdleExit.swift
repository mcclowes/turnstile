import Foundation

/// When an idle daemon should exit. Builds seen outside turnstile keep it up longer, since it can only
/// record them while it's awake.
public enum IdleExit {
    public static let afterEscape: Double = 4 * 3600

    public static func isDue(now: Double, idleSince: Double, lastEscape: Double?, idleExit: Double, afterEscape: Double = afterEscape) -> Bool {
        guard now - idleSince > idleExit else { return false }
        guard let lastEscape else { return true }
        return now - lastEscape > afterEscape
    }
}
