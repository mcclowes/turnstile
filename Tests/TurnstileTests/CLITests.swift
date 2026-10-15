import Foundation
import Testing

@testable import TurnstileCore

struct CLITests {
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
}
