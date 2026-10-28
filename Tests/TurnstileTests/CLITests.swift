import Foundation
import Testing

@testable import TurnstileCore

struct CLITests {
    @Test(
        arguments: ["--days", "--limit"],
        [nil, "", "0", "-1", "not-a-number", "1.5", String(repeating: "9", count: 30)] as [String?])
    func historyRejectsInvalidNumbers(_ option: String, _ value: String?) throws {
        let arguments = ["history", "--json", option] + (value.map { [$0] } ?? [])
        let (run, daemon) = try ShimRun.run(cliArguments: arguments) { paths in
            FakeDaemon(socket: paths.socket) { _, _, _, _ in }
        }
        #expect(run.exitCode == 64)
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.contains("usage: turnstile history"))
        #expect(run.toolRuns.isEmpty)
        #expect(daemon.types.isEmpty)
        #expect(run.ungated.isEmpty)
    }

    @Test func historyDefaultsKeepTotalsBeyondTheDisplayLimit() throws {
        let summary = try historyReport(["history", "--json"])
        #expect(summary.days == 30)
        #expect(summary.jobs == 22)
        #expect(summary.commands.count == 20)
        #expect(summary.more == 2)
        #expect(summary.commands.first?.key == "older command")
        #expect(summary.commands.last?.key == "recent 2")
    }

    @Test func historyOptionsFilterWindowAndCommandTable() throws {
        let summary = try historyReport(["history", "--days", "7", "--limit", "1", "--json"])
        #expect(summary.days == 7)
        #expect(summary.jobs == 21)
        #expect(summary.commands.map(\.key) == ["recent 20"])
        #expect(summary.more == 20)
    }

    @Test(
        .bug("https://github.com/mcclowes/turnstile/issues/121"),
        arguments: [
            ["run", "--help"], ["run", "-h"],
            ["run", "--class", "test", "--help"], ["run", "--class=browser", "-h"],
        ])
    func runHelpStopsBeforeExecutableLookup(_ arguments: [String]) throws {
        let (run, daemon) = try ShimRun.run(cliArguments: arguments) { paths in
            FakeDaemon(socket: paths.socket) { _, _, _, _ in }
        }
        #expect(run.exitCode == 0)
        #expect(run.stdout.contains("turnstile run [--class compile|test|browser]"))
        #expect(run.stderr.isEmpty)
        #expect(run.toolRuns.isEmpty)
        #expect(daemon.types.isEmpty)
        #expect(run.ungated.isEmpty)
    }

    @Test(arguments: ["--help", "-h"])
    func wrappedHelpFlagsStillReachTheTool(_ flag: String) throws {
        let (run, daemon) = try ShimRun.run(
            cliArguments: ["run", "--class", "test", "--", "swift", flag]
        ) { paths in
            FakeDaemon(socket: paths.socket) { message, _, send, _ in
                if message.type == "request" { send(reply("admitted", job: 12)) }
                if message.type == "finished" { send(reply("ok")) }
            }
        }
        #expect(run.exitCode == 0)
        #expect(run.stdout == "fake swift \(flag)\n")
        #expect(run.stderr.isEmpty)
        #expect(run.toolRuns.count == 1)
        let request = try #require(daemon.received.first { $0.message.type == "request" }?.message)
        #expect(request.argv == [run.toolPath, flag])
        #expect(request.resourceClass == .test)
        #expect(daemon.types == ["request", "started", "finished"])
    }

    @Test(arguments: [["run", "--class"], ["run", "--class=test", "--class"]])
    func missingClassValueStopsBeforeExecutableLookup(_ arguments: [String]) throws {
        let (run, daemon) = try ShimRun.run(cliArguments: arguments) { paths in
            FakeDaemon(socket: paths.socket) { _, _, _, _ in }
        }
        #expect(run.exitCode == 64)
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.contains("usage: turnstile run"))
        #expect(run.toolRuns.isEmpty)
        #expect(daemon.types.isEmpty)
        #expect(run.ungated.isEmpty)
    }

    @Test(arguments: [
        ("{}", "{}", "only agent compiles may be paused"),
        (#"{"throttle":{"pause":true}}"#, "{}", "all agent jobs may be paused"),
        (#"{"throttle":{"pause":false}}"#, "{}", "never paused"),
        (#"{"throttle":{"pause":true}}"#, #"{"throttle":{"pause":false}}"#, "never paused"),
        (#"{"throttle":{"pause":false}}"#, #"{"throttle":{"pause":true}}"#, "all agent jobs may be paused"),
    ])
    func configShowsEffectivePausePolicy(_ global: String, _ project: String, _ summary: String) throws {
        let (run, daemon) = try ShimRun.run(cliArguments: ["config", "show"]) { paths in
            let root = URL(fileURLWithPath: paths.home).deletingLastPathComponent()
            let config = root.appendingPathComponent("config")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try global.write(to: config.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
            try project.write(to: root.appendingPathComponent(".turnstilerc"), atomically: true, encoding: .utf8)
            return FakeDaemon(socket: paths.socket) { _, _, _, _ in }
        }
        #expect(run.exitCode == 0)
        #expect(run.stderr.isEmpty)
        #expect(run.stdout.split(separator: "\n").contains("  pause         \(summary)"))
        #expect(daemon.types.isEmpty)
        #expect(run.toolRuns.isEmpty)
    }

    @Test(
        .bug("https://github.com/mcclowes/turnstile/issues/66"),
        arguments: [
            ["run", "--"], ["run", "--class", "test", "--"],
        ])
    func disabledEnvironmentRunsWithoutContactingDaemon(_ invocation: [String]) throws {
        let (run, daemon) = try ShimRun.run(
            cliArguments: invocation + ["swift", "build", "a b"],
            environment: ["TURNSTILE_DISABLE": "1", "FAKE_EXIT": "7"]
        ) { paths in
            FakeDaemon(socket: paths.socket) { message, _, send, _ in
                if message.type == "request" { send(reply("admitted", job: 7)) }
                if message.type == "finished" { send(reply("ok")) }
            }
        }
        #expect(run.exitCode == 7)
        #expect(!run.signaled)
        #expect(run.stdout == "fake swift build a b\n")
        #expect(run.stderr.isEmpty)
        #expect(run.toolRuns == ["run build a b token=none"])
        #expect(daemon.types.isEmpty)
        #expect(run.ungated.isEmpty)
    }

    @Test(arguments: [nil, "", "0", "true"] as [String?])
    func otherDisableValuesKeepGating(_ value: String?) throws {
        let environment = value.map { ["TURNSTILE_DISABLE": $0] } ?? [:]
        let (run, daemon) = try ShimRun.run(
            cliArguments: ["run", "--class", "test", "--", "swift", "build"],
            environment: environment
        ) { paths in
            FakeDaemon(socket: paths.socket) { message, _, send, _ in
                if message.type == "request" { send(reply("admitted", job: 8)) }
                if message.type == "finished" { send(reply("ok")) }
            }
        }
        #expect(run.exitCode == 0)
        #expect(run.stdout == "fake swift build\n")
        #expect(run.toolRuns.count == 1)
        #expect(run.toolRuns.first?.hasPrefix("run build token=8:") == true)
        let request = try #require(daemon.received.first { $0.message.type == "request" }?.message)
        #expect(request.resourceClass == .test)
        #expect(request.argv == [run.toolPath, "build"])
        #expect(daemon.types == ["request", "started", "finished"])
        #expect(run.ungated.isEmpty)
    }

    private func historyReport(_ arguments: [String]) throws -> HistorySummary {
        let (run, daemon) = try ShimRun.run(cliArguments: arguments) { paths in
            let store = try Store(path: paths.database)
            let now = Date().timeIntervalSince1970
            let recentCommands = 21
            for index in 0...recentCommands {
                let older = index == recentCommands
                let key = older ? "older command" : "recent \(index)"
                let age: TimeInterval = older ? 10 : 2
                let finishedAt = now - age * 86_400
                let id = store.insertJob(
                    state: "queued", resourceClass: .test, key: key, root: "/fixture/repo", cwd: "/fixture/repo",
                    argv: [key], agent: true, clientPid: 1, estimate: Bytes.mb, now: finishedAt - 2)
                store.markStarted(id, childPid: 2, now: finishedAt - 1)
                store.markFinished(
                    id, outcome: "ok", exitCode: 0, signal: nil,
                    peak: UInt64(older ? 99 : index + 1) * Bytes.mb, ranFor: 1, now: finishedAt)
            }
            return FakeDaemon(socket: paths.socket) { _, _, _, _ in }
        }
        #expect(run.exitCode == 0)
        #expect(run.stderr.isEmpty)
        #expect(run.toolRuns.isEmpty)
        #expect(daemon.types.isEmpty)
        #expect(run.ungated.isEmpty)
        return try JSONDecoder().decode(HistorySummary.self, from: Data(run.stdout.utf8))
    }
}
