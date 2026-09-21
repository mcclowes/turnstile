import Foundation
import Testing
@testable import TurnstileCore

struct RunLogsTests {
    @Test func eachJobHasOneLogPath() {
        #expect(Paths(home: "/h").log(forJob: 42) == "/h/logs/42.log")
    }

    @Test func readsTheJobBackFromTheFileName() {
        #expect(RunLogs.job(fromFileName: "42.log") == 42)
        #expect(RunLogs.job(fromFileName: "notes.txt") == nil)
        #expect(RunLogs.job(fromFileName: "x.log") == nil)
    }

    @Test func failedRunsAreKeptForAWeek() {
        for outcome in ["failed", "signaled", "killed"] {
            #expect(RunLogs.retention(outcome: outcome) == 7 * 86400)
        }
    }

    @Test func everythingElseIsKeptForADay() {
        for outcome in ["ok", "cancelled", "lost", nil] {
            #expect(RunLogs.retention(outcome: outcome) == 86400)
        }
    }

    @Test func parsesJobTargets() {
        #expect(RunLogs.job(fromTarget: "12") == 12)
        #expect(RunLogs.job(fromTarget: "#12") == 12)
        #expect(RunLogs.job(fromTarget: "swift") == nil)
        #expect(RunLogs.job(fromTarget: "-3") == nil)
    }

    @Test func snapshotsFromOlderDaemonsDecodeWithoutALog() throws {
        let json = #"{"id":1,"project":"p","key":"k","outcome":"ok","finishedAt":0}"#
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
        #expect(entry.log == nil)
    }
}
