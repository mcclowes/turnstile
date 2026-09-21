import Testing
@testable import TurnstileCore

@Suite(.bug(id: 30))
struct IdleExitTests {
    @Test func exitsOnceIdleForTheTimeout() {
        #expect(!IdleExit.isDue(now: 1000, idleSince: 0, lastEscape: nil, idleExit: 1800))
        #expect(IdleExit.isDue(now: 2000, idleSince: 0, lastEscape: nil, idleExit: 1800))
    }

    /// A machine that builds in Xcode keeps the daemon up to watch it, rather than letting it sleep through the builds.
    @Test func staysUpLongerWhileBuildsRunOutsideTurnstile() {
        #expect(!IdleExit.isDue(now: 5000, idleSince: 0, lastEscape: 3000, idleExit: 1800, afterEscape: 4 * 3600))
        #expect(IdleExit.isDue(now: 3000 + 4 * 3600 + 1, idleSince: 0, lastEscape: 3000, idleExit: 1800, afterEscape: 4 * 3600))
    }

    @Test func anOldEscapeDoesntHoldItUp() {
        #expect(IdleExit.isDue(now: 30000, idleSince: 20000, lastEscape: 100, idleExit: 1800, afterEscape: 4 * 3600))
    }
}
