import Foundation
import Testing
@testable import TurnstileCore

struct HistoryTests {
    func row(
        _ root: String = "/code/api", _ key: String = "swift test", outcome: String = "ok",
        peak: UInt64? = Bytes.gb, duration: Double? = 60, wait: Double? = 0, agent: Bool = true, finishedAt: Double = 0
    ) -> HistoryRow {
        HistoryRow(root: root, key: key, agent: agent, outcome: outcome, peak: peak, duration: duration, wait: wait, finishedAt: finishedAt)
    }

    @Test func summarizesEachCommandPerProject() throws {
        let rows = [
            row(peak: 2 * Bytes.gb, duration: 100, finishedAt: 1),
            row(peak: 4 * Bytes.gb, duration: 200, finishedAt: 2),
            row(peak: 3 * Bytes.gb, duration: 300, finishedAt: 3),
            row("/code/web", "npm run build", peak: Bytes.gb, duration: 10),
            row("/code/web", "swift test", peak: Bytes.gb, duration: 10),
        ]
        let summary = HistorySummary.summarize(rows, days: 30, limit: 20)

        #expect(summary.jobs == 5)
        #expect(summary.projects == 2)
        #expect(summary.commands.count == 3)
        let swift = try #require(summary.commands.first)
        #expect(swift.project == "api")
        #expect(swift.key == "swift test")
        #expect(swift.runs == 3)
        #expect(swift.estimate == 4 * Bytes.gb)
        #expect(swift.worstPeak == 4 * Bytes.gb)
        #expect(swift.usualDuration == 200)
        // The same command in another project is its own row, since that's how the scheduler estimates it.
        #expect(summary.commands.dropFirst().map(\.project) == ["web", "web"])
    }

    /// The same window the scheduler uses: the worst peak of the last five runs, not of every run kept.
    @Test func theEstimateFollowsTheLastFiveRuns() throws {
        var rows = [row(peak: 9 * Bytes.gb, finishedAt: 0)]
        rows += (1...5).map { row(peak: Bytes.gb, finishedAt: Double($0)) }
        let command = try #require(HistorySummary.summarize(rows, days: 30, limit: 20).commands.first)

        #expect(command.estimate == Bytes.gb)
        #expect(command.worstPeak == 9 * Bytes.gb)
    }

    /// A failed run still costs the memory it used, so it counts; its run time doesn't, since it stopped early.
    @Test func failedRunsCountForMemoryButNotForTime() throws {
        let rows = [
            row(peak: 2 * Bytes.gb, duration: 100, finishedAt: 1),
            row(outcome: "failed", peak: 5 * Bytes.gb, duration: 3, finishedAt: 2),
        ]
        let command = try #require(HistorySummary.summarize(rows, days: 30, limit: 20).commands.first)

        #expect(command.runs == 2)
        #expect(command.estimate == 5 * Bytes.gb)
        #expect(command.usualDuration == 100)
    }

    @Test func mergedRunsCountButDontSkewCosts() {
        let rows = [
            row(peak: 4 * Bytes.gb, duration: 100),
            row(outcome: "joined", peak: nil, duration: nil, wait: nil),
            row(outcome: "superseded", peak: nil, duration: nil, wait: nil),
        ]
        let summary = HistorySummary.summarize(rows, days: 30, limit: 20)

        #expect(summary.jobs == 3)
        #expect(summary.outcomes["joined"] == 1)
        #expect(summary.outcomes["superseded"] == 1)
        #expect(summary.commands.count == 1)
        #expect(summary.commands[0].runs == 1)
        #expect(HistoryFormatter.render(summary, here: nil).contains("merged: 1 joined a run already going"))
    }

    @Test func waitsReportPercentilesAndTheAgentTimeoutBand() throws {
        let waits: [Double] = [0, 1, 2, 3, 4, 5, 6, 7, 130, 200]
        let summary = HistorySummary.summarize(waits.map { row(wait: $0) }, days: 7, limit: 20)
        let measured = try #require(summary.waits)

        #expect(measured.started == 10)
        #expect(measured.median == 4.5)
        #expect(measured.p90 == 200)
        #expect(measured.longest == 200)
        #expect(measured.overTwoMinutes == 2)
        #expect(HistoryFormatter.render(summary, here: nil).contains("2 over 2m"))
    }

    @Test func jobsThatNeverStartedLeaveTheWaitsAlone() {
        let summary = HistorySummary.summarize([row(wait: nil), row(wait: nil)], days: 30, limit: 20)
        #expect(summary.waits == nil)
        #expect(!HistoryFormatter.render(summary, here: nil).contains("waits:"))
    }

    @Test func biggestCommandsComeFirstAndTheRestAreCounted() {
        let rows = (1...5).map { row("/code/p\($0)", "cmd \($0)", peak: UInt64($0) * Bytes.gb) }
        let summary = HistorySummary.summarize(rows, days: 30, limit: 2)

        #expect(summary.commands.map(\.key) == ["cmd 5", "cmd 4"])
        #expect(summary.more == 3)
        #expect(HistoryFormatter.render(summary, here: nil).contains("and 3 more"))
    }

    /// A run that ended before the daemon could sample it records nothing, and says so rather than guessing.
    @Test func peaksAndTimesAreOptional() {
        let summary = HistorySummary.summarize([row(peak: nil, duration: nil)], days: 30, limit: 20)
        #expect(summary.commands[0].estimate == nil)
        #expect(summary.commands[0].worstPeak == nil)
        #expect(summary.commands[0].usualDuration == nil)
        #expect(HistoryFormatter.render(summary, here: nil).contains("-"))
    }

    @Test func oneProjectDropsTheProjectColumn() {
        let summary = HistorySummary.summarize([row()], days: 30, limit: 20)
        let here = HistoryFormatter.render(summary, here: "/code/api")
        #expect(here.contains("in api over 30 days"))
        #expect(!here.contains("project"))
        #expect(HistoryFormatter.render(summary, here: nil).contains("project"))
    }

    @Test func nothingRanIsSaidPlainly() {
        let summary = HistorySummary.summarize([], days: 14, limit: 20)
        #expect(HistoryFormatter.render(summary, here: nil) == "history: nothing ran in the last 14 days")
        #expect(HistoryFormatter.render(summary, here: "/code/api") == "history: nothing ran in api in the last 14 days")
    }

    @Test func troubleIsCalledOut() {
        let rows = [row(outcome: "killed"), row(outcome: "failed"), row(outcome: "ok")]
        let rendered = HistoryFormatter.render(HistorySummary.summarize(rows, days: 30, limit: 20), here: nil)
        #expect(rendered.contains("outcomes: 1 failed, 1 killed"))
    }

    @Test func theStoreReadsBackWhatItRecorded() throws {
        let path = NSTemporaryDirectory() + "turnstile-history-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Store(path: path)
        let id = store.insertJob(
            state: "queued", resourceClass: .test, key: "swift test", root: "/code/api", cwd: "/code/api",
            argv: ["swift", "test"], agent: true, clientPid: 1, estimate: Bytes.gb, now: 1000
        )
        store.markStarted(id, childPid: 2, now: 1030)
        store.markFinished(id, outcome: "ok", exitCode: 0, signal: nil, peak: 3 * Bytes.gb, ranFor: 42, now: 1100)

        #expect(store.history(since: 0, root: nil) == [HistoryRow(
            root: "/code/api", key: "swift test", agent: true, outcome: "ok",
            peak: 3 * Bytes.gb, duration: 42, wait: 30, finishedAt: 1100
        )])
        #expect(store.history(since: 0, root: "/code/web").isEmpty)
        #expect(store.history(since: 1200, root: nil).isEmpty)
    }

    /// The scheduler and the report have to agree, or the table explains an admission that never happened.
    @Test func theSummaryMatchesWhatTheSchedulerLearned() throws {
        let path = NSTemporaryDirectory() + "turnstile-history-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Store(path: path)
        for (index, peak) in [9, 1, 2, 3, 4, 5].map({ UInt64($0) * Bytes.gb }).enumerated() {
            let id = store.insertJob(
                state: "queued", resourceClass: .compile, key: "swift build", root: "/code/api", cwd: "/code/api",
                argv: ["swift", "build"], agent: true, clientPid: 1, estimate: Bytes.gb, now: Double(index)
            )
            store.markStarted(id, childPid: 2, now: Double(index))
            store.markFinished(id, outcome: "ok", exitCode: 0, signal: nil, peak: peak, ranFor: 30, now: Double(index))
        }
        let summary = HistorySummary.summarize(store.history(since: 0, root: nil), days: 30, limit: 20)

        #expect(summary.commands[0].estimate == store.usualPeak(key: "swift build", root: "/code/api"))
        #expect(summary.commands[0].usualDuration == store.usualDuration(key: "swift build", root: "/code/api"))
    }
}
