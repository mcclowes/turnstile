import Foundation
import Testing

@testable import TurnstileCore
@testable import turnstile

@Suite(.serialized)
struct TickDiagnosticsTests {
    @Test func aSlowEscapeScanReportsItsPhaseWithoutWaiting() throws {
        let harness = try DaemonHarness()
        var time = 100.0
        var messages: [String] = []
        harness.daemon.diagnosticClock = { time }
        harness.daemon.diagnosticLog = { messages.append($0) }
        harness.daemon.ticks = 1
        harness.daemon.probe.table = {
            time += 6
            return [:]
        }

        harness.daemon.tick()

        #expect(messages == ["daemon tick took 6s; slowest phase: escape scan (6s)"])
    }

    @Test func normalTicksRemainSilentAndALongGapIsReportedOnce() throws {
        let harness = try DaemonHarness()
        var time = 100.0
        var messages: [String] = []
        harness.daemon.diagnosticClock = { time }
        harness.daemon.diagnosticLog = { messages.append($0) }
        harness.daemon.probe.table = { [:] }

        harness.daemon.tick()
        #expect(messages.isEmpty)
        time += 135
        harness.daemon.tick()
        #expect(messages == ["daemon scheduler had a 2m15s gap between ticks"])
        time += 1
        harness.daemon.tick()
        #expect(messages.count == 1)
    }

    @Test(arguments: [(4.9, false), (5.0, true), (5.1, true)])
    func slowTickReportingStartsAtFiveSeconds(seconds: Double, reports: Bool) {
        var timing = TickDiagnostics()
        #expect(timing.begin(at: 100) == nil)
        timing.completePhase("memory observation", at: 100 + seconds)
        let message = timing.finish(at: 100 + seconds)
        #expect((message != nil) == reports)
    }

    @Test(arguments: [(29.9, false), (30.0, true), (30.1, true)])
    func gapReportingStartsAtThirtySeconds(seconds: Double, reports: Bool) {
        var timing = TickDiagnostics()
        #expect(timing.begin(at: 0) == nil)
        #expect(timing.finish(at: 0) == nil)
        #expect((timing.begin(at: seconds) != nil) == reports)
    }

    @Test func aSlowTickReportsItsLongestPhaseAndDoesNotBecomeTheNextGap() {
        var timing = TickDiagnostics()
        #expect(timing.begin(at: 0) == nil)
        timing.completePhase("memory observation", at: 2)
        timing.completePhase("job monitoring", at: 130)
        timing.completePhase("scheduling", at: 135)
        #expect(timing.finish(at: 135) == "daemon tick took 2m15s; slowest phase: job monitoring (2m08s)")

        #expect(timing.begin(at: 136) == nil)
        timing.completePhase("memory observation", at: 136.1)
        #expect(timing.finish(at: 136.1) == nil)
    }
}
