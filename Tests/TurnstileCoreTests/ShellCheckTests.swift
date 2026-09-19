import Foundation
import Testing
@testable import TurnstileCore

struct ShellCheckTests {
    @Test func asksEachShellWhereItsToolsCameFrom() {
        let script = ShellCheck.script(tools: ["swift", "npm"])
        #expect(script.contains("command -v"))
        #expect(script.contains("swift"))
        #expect(script.contains("npm"))
    }

    @Test func readsWhichToolsMissTheShims() {
        let output = """
            swift\t/Users/me/.turnstile/shims/swift
            npm\t/opt/homebrew/bin/npm
            cargo\t
            """
        let verdict = ShellCheck.verdict(output: output, shimsDir: "/Users/me/.turnstile/shims")
        #expect(verdict.shimmed == ["swift"])
        #expect(verdict.shadowed == ["npm (/opt/homebrew/bin/npm)"])
        #expect(verdict.missing == ["cargo"])
    }

    @Test func aShellThatCantBeAskedCountsAsNothingShimmed() {
        let verdict = ShellCheck.verdict(output: "", shimsDir: "/shims")
        #expect(verdict.shimmed.isEmpty)
        #expect(verdict.shadowed.isEmpty)
    }

    /// Claude Code replays a snapshot of the shell it started in, so a session older than `turnstile init` keeps the old PATH.
    @Test func readsThePathOutOfAnAgentShellSnapshot() {
        let snapshot = """
            alias ll='ls -l'
            export PATH='/usr/bin:/bin'
            export PATH='/Users/me/.turnstile/shims:/usr/bin:/bin'
            """
        #expect(ShellCheck.snapshotPath(snapshot) == "/Users/me/.turnstile/shims:/usr/bin:/bin")
        #expect(ShellCheck.snapshotPath("export EDITOR=vim\n") == nil)
    }

    @Test func runsARealShellAndSeesTheShims() throws {
        let shims = NSTemporaryDirectory() + "shims-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: shims, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: shims) }
        FileManager.default.createFile(atPath: shims + "/swift", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let output = ShellCheck.ask(ShellCheck.Probe(name: "sh -c", binary: "/bin/sh", arguments: ["-c"]),
                                    tools: ["swift"], environment: ["PATH": "\(shims):/usr/bin:/bin"])
        #expect(ShellCheck.verdict(output: output ?? "", shimsDir: shims).shimmed == ["swift"])
    }
}

struct AgentInstructionsTests {
    @Test func tellsAgentsWhatGoesAroundTheShims() {
        let snippet = AgentInstructions.snippet
        #expect(snippet.contains("node_modules/.bin"))
        #expect(snippet.contains("turnstile run"))
        #expect(snippet.hasSuffix("\n") == false)
    }
}
