import Testing

@testable import TurnstileCore

struct CLITests {
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
        #expect(request.argv == ["swift", "build"])
        #expect(daemon.types == ["request", "started", "finished"])
        #expect(run.ungated.isEmpty)
    }
}
