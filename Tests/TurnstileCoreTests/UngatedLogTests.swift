import Foundation
import Testing
@testable import TurnstileCore

struct UngatedLogTests {
    @Test func linesRoundTrip() {
        let entry = UngatedLog.Entry(time: 1_800_000_000, cause: "sandboxed", cwd: "/Users/me/app\twith tab", command: "swift build")
        let parsed = UngatedLog.parse(UngatedLog.line(entry) + UngatedLog.line(entry))
        #expect(parsed == [UngatedLog.Entry(time: 1_800_000_000, cause: "sandboxed", cwd: "/Users/me/app with tab", command: "swift build")].flatMap { [$0, $0] })
    }

    @Test func skipsLinesItCantRead() {
        #expect(UngatedLog.parse("garbage\n\n1800000000\tonly two\n").isEmpty)
    }

    @Test func appendsAndRotates() throws {
        let path = NSTemporaryDirectory() + "ungated-" + UUID().uuidString.prefix(8) + ".log"
        defer { try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(atPath: path + ".1") }
        let entry = UngatedLog.Entry(time: 1, cause: "c", cwd: "/", command: "make")
        UngatedLog.append(entry, to: path, limit: 10)
        UngatedLog.append(entry, to: path, limit: 10)
        #expect(UngatedLog.parse(try String(contentsOfFile: path, encoding: .utf8)).count == 1)
        #expect(FileManager.default.fileExists(atPath: path + ".1"))
    }

    @Test func summarisesRecentRuns() {
        let now = 1_800_000_000.0
        let entries = [
            UngatedLog.Entry(time: now - 2 * 86400, cause: "old", cwd: "/a", command: "make"),
            UngatedLog.Entry(time: now - 3600, cause: "sandboxed", cwd: "/a", command: "swift build"),
            UngatedLog.Entry(time: now - 60, cause: "daemon unavailable", cwd: "/b", command: "npm test"),
        ]
        let summary = UngatedLog.summary(entries, since: now - 86400)
        #expect(summary?.count == 2)
        #expect(summary?.latest.command == "npm test")
        #expect(UngatedLog.summary(entries, since: now) == nil)
    }

    @Test func describesTheLastDay() {
        let now = 1_800_000_000.0
        let entries = [
            UngatedLog.Entry(time: now - 3600, cause: "a sandbox blocked the daemon's socket", cwd: "/Users/me/a", command: "swift build"),
            UngatedLog.Entry(time: now - 90, cause: "the daemon was unavailable", cwd: "/Users/me/b", command: "npm test"),
        ]
        #expect(UngatedLog.describe(entries, now: now, home: "/Users/me")
            == "2 runs went ungated in the last day; the latest, `npm test` in ~/b 1m30s ago, because the daemon was unavailable")
        #expect(UngatedLog.describe(Array(entries.prefix(1)), now: now, home: "/Users/me")
            == "1 run went ungated in the last day; the latest, `swift build` in ~/a 1h00m ago, because a sandbox blocked the daemon's socket")
        #expect(UngatedLog.describe([], now: now, home: "/Users/me") == nil)
    }
}
