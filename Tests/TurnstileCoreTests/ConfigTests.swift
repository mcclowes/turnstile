import Foundation
import Testing
@testable import TurnstileCore

struct BytesTests {
    @Test(arguments: [
        ("4GB", UInt64(4) << 30), ("512 MB", 512 << 20), ("1.5g", 1536 << 20), ("2048", 2048 << 20), ("1 TB", 1 << 40),
    ])
    func parses(text: String, bytes: UInt64) {
        #expect(Bytes.parse(text) == bytes)
    }

    @Test func rejectsNonsense() {
        #expect(Bytes.parse("lots") == nil)
        #expect(Bytes.parse("4 parsecs") == nil)
    }

    @Test(arguments: [(UInt64(512) << 20, "512 MB"), (UInt64(4) << 30, "4 GB"), (1536 << 20, "1.5 GB"), (UInt64(12) << 30, "12 GB")])
    func formats(bytes: UInt64, text: String) {
        #expect(Bytes.format(bytes) == text)
    }
}

struct ConfigTests {
    @Test func decodesAProjectFile() throws {
        let json = """
            {
              "commands": {"swift test": {"class": "test", "memory": "6GB"}, "make docs": "pass"},
              "scripts": {"e2e": "browser"},
              "throttle": {"jobs": 2, "nodeHeap": "3GB", "maxMemory": 8192, "pause": false}
            }
            """
        let file = try ConfigFile.decode(Data(json.utf8))
        #expect(file.commands?["swift test"] == .gate(.test, memory: 6 * Bytes.gb))
        #expect(file.commands?["make docs"] == .pass)
        #expect(file.scripts?["e2e"] == .gate(.browser, memory: nil))
        #expect(file.throttle == ThrottleConfig(jobs: 2, nodeHeap: 3 * Bytes.gb, maxMemory: 8 * Bytes.gb, pause: false))
    }

    @Test func decodesMachineSettings() throws {
        let json = #"{"concurrency": {"test": 5}, "reserve": "4GB", "shims": {"add": ["bazel"], "remove": ["make"]}}"#
        let machine = try ConfigFile.decode(Data(json.utf8)).machine
        #expect(machine.concurrencyLimit(for: .test) == 5)
        #expect(machine.concurrencyLimit(for: .compile) == 3)
        #expect(machine.reserveBytes == 4 * Bytes.gb)
        #expect(machine.shims?.add == ["bazel"])
    }

    @Test func emptyFileIsFine() throws {
        #expect(try ConfigFile.decode(Data("\n".utf8)) == ConfigFile())
    }

    @Test func badValuesExplainThemselves() {
        #expect(throws: DecodingError.self) { try ConfigFile.decode(Data(#"{"commands": {"swift": "fast"}}"#.utf8)) }
        #expect(throws: DecodingError.self) { try ConfigFile.decode(Data(#"{"throttle": {"maxMemory": "big"}}"#.utf8)) }
    }

    @Test func projectThrottleOverridesGlobal() {
        let config = Config(
            global: ConfigFile(throttle: ThrottleConfig(jobs: 8, killMultiplier: 4)),
            project: ConfigFile(throttle: ThrottleConfig(jobs: 2))
        )
        #expect(config.throttle == ThrottleConfig(jobs: 2, killMultiplier: 4))
    }

    @Test func findsTheNearestTurnstilerc() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turnstile-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("packages/web/src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"throttle": {"jobs": 1}}"#.write(to: root.appendingPathComponent(".turnstilerc"), atomically: true, encoding: .utf8)
        try #"{"throttle": {"jobs": 2}}"#.write(to: root.appendingPathComponent("packages/web/.turnstilerc"), atomically: true, encoding: .utf8)

        let config = try ConfigLoader.load(cwd: nested.path, environment: ["TURNSTILE_CONFIG_DIR": root.appendingPathComponent("none").path])
        #expect(config.throttle.jobs == 2)
        #expect(config.projectRoot?.hasSuffix("packages/web") == true)
    }
}

struct ShellSetupTests {
    @Test func installIsIdempotent() {
        let snippet = ShellSetup.snippet(shell: .zsh, shimsDir: "/Users/me/.turnstile/shims")
        let once = ShellSetup.install(snippet, into: "export EDITOR=vim\n")
        #expect(once == "export EDITOR=vim\n\n\(snippet)\n")
        #expect(ShellSetup.install(snippet, into: once) == once)
        #expect(ShellSetup.remove(from: once) == "export EDITOR=vim\n")
    }

    @Test func removeLeavesOtherLinesAlone() {
        let contents = "a\n\n\(ShellSetup.begin)\nstuff\n\(ShellSetup.end)\n\nb\n"
        #expect(ShellSetup.remove(from: contents) == "a\n\nb\n")
    }

    @Test(arguments: ShellSetup.Shell.allCases)
    func snippetsMoveShimsToTheFront(shell: ShellSetup.Shell) throws {
        let shims = "/tmp/turnstile test/shims"
        let path = "/usr/bin:\(shims):/bin"
        let snippet = ShellSetup.snippet(shell: shell, shimsDir: shims)
        guard let binary = ["zsh": "/bin/zsh", "bash": "/bin/bash", "fish": "/opt/homebrew/bin/fish"][shell.rawValue],
              FileManager.default.isExecutableFile(atPath: binary) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        let script = shell == .fish ? "set -gx PATH (string split : \"\(path)\"); \(snippet); string join : $PATH" : "PATH='\(path)'; \(snippet)\n\(snippet)\nprintf %s \"$PATH\""
        process.arguments = shell == .fish ? ["--no-config", "-c", script] : ["-f", "-c", script].filter { shell == .zsh || $0 != "-f" }
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(result == "\(shims):/usr/bin:/bin")
    }

    /// `nvm use` and `mise activate` put their bin dirs first after startup; the next prompt moves the shims back.
    @Test(arguments: [ShellSetup.Shell.zsh, .bash])
    func promptHookPutsShimsBackInFront(shell: ShellSetup.Shell) throws {
        let shims = "/tmp/turnstile test/shims"
        let snippet = ShellSetup.snippet(shell: shell, shimsDir: shims)
        let prompt = shell == .zsh ? "for hook in $precmd_functions; do $hook; done" : "eval \"$PROMPT_COMMAND\""
        let hooks = shell == .zsh ? "print -r -- ${(j: :)precmd_functions}" : "printf %s \"$PROMPT_COMMAND\""
        let script = """
            PATH='/usr/bin:/bin'
            \(snippet)
            \(snippet)
            PATH="/nvm/v22/bin:$PATH"
            \(prompt)
            printf '%s\\n' "$PATH"
            \(hooks)
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell == .zsh ? "/bin/zsh" : "/bin/bash")
        process.arguments = shell == .zsh ? ["-f", "-c", script] : ["--norc", "--noprofile", "-c", script]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        #expect(lines.first == "\(shims):/nvm/v22/bin:/usr/bin:/bin")
        #expect(lines.last == "_turnstile_shims_first")
    }
}

struct AgentTests {
    @Test func detectsAgents() {
        #expect(Agent.isAgent(environment: ["CLAUDECODE": "1"], interactive: true))
        #expect(Agent.isAgent(environment: ["CODEX_SANDBOX": "seatbelt"], interactive: true))
        #expect(!Agent.isAgent(environment: [:], interactive: true))
        #expect(Agent.isAgent(environment: [:], interactive: false))
        #expect(!Agent.isAgent(environment: ["CLAUDECODE": "1", "TURNSTILE_AGENT": "0"], interactive: true))
        #expect(Agent.isAgent(environment: ["MY_BOT": "1"], extraMarkers: ["MY_BOT"], interactive: true))
    }
}
