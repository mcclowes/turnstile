import Darwin
import Foundation
import TurnstileCore

/// `turnstile doctor`: checks every link in the chain from shell to daemon, and says how to fix what's broken.
enum Doctor {
    enum Level { case ok, note, problem }

    struct Finding {
        var level: Level
        var topic: String
        var text: String
        var fix: String?
    }

    static func main(_ args: [String]) -> Never {
        let findings = run()
        for finding in findings {
            let mark: String
            switch finding.level {
            case .ok: mark = "ok  "
            case .note: mark = "note"
            case .problem: mark = "FAIL"
            }
            print("\(mark)  \(finding.topic.padding(toLength: 9, withPad: " ", startingAt: 0)) \(finding.text)")
            if let fix = finding.fix { print("                 fix: \(fix)") }
        }
        let failures = findings.filter { $0.level == .problem }.count
        print("")
        print(failures == 0 ? "turnstile looks healthy" : "\(failures) problem\(failures == 1 ? "" : "s") found")
        exit(failures == 0 ? 0 : 1)
    }

    static func run() -> [Finding] {
        let environment = ProcessInfo.processInfo.environment
        let paths = Paths(environment: environment)
        let config = Supervisor.loadConfig(environment: environment)
        var findings: [Finding] = []
        findings += install(paths: paths)
        findings += shims(paths: paths, config: config, environment: environment)
        findings += switches(paths: paths, environment: environment)
        findings += configuration()
        findings += daemon(paths: paths)
        findings += ungated(paths: paths, environment: environment)
        findings += system(environment: environment, config: config)
        return findings
    }

    static func install(paths: Paths) -> [Finding] {
        let installed = paths.bin + "/turnstile"
        guard FileManager.default.isExecutableFile(atPath: installed) else {
            return [Finding(level: .problem, topic: "install", text: "turnstile isn't installed in \(paths.home)", fix: "turnstile init")]
        }
        if let me = executablePath(), Resolver.canonical(installed) != me,
           !FileManager.default.contentsEqual(atPath: installed, andPath: me) {
            return [Finding(level: .problem, topic: "install", text: "\(installed) differs from this turnstile (\(me))", fix: "run `turnstile init` from the build you want installed")]
        }
        return [Finding(level: .ok, topic: "install", text: "\(installed), version \(Turnstile.version)")]
    }

    static func shims(paths: Paths, config: Config, environment: [String: String]) -> [Finding] {
        guard FileManager.default.isExecutableFile(atPath: paths.bin + "/turnstile") else { return [] }
        let names = CLI.shimNames(config: config.machine)
        let target = Resolver.canonical(paths.bin + "/turnstile")
        let broken = names.filter { Resolver.canonical(paths.shims + "/" + $0) != target }
        if !broken.isEmpty {
            return [Finding(level: .problem, topic: "shims", text: "missing or stale: \(broken.joined(separator: " "))", fix: "turnstile shims")]
        }

        var findings: [Finding] = []
        let path = environment["PATH"] ?? ""
        let shimsDir = Resolver.canonical(paths.shims)
        let dirs = path.split(separator: ":").map { Resolver.canonical(String($0)) }
        guard dirs.contains(shimsDir) else {
            return [Finding(
                level: .problem, topic: "PATH", text: "\(paths.shims) isn't on this shell's PATH, so nothing is gated",
                fix: "open a new shell after `turnstile init`, or run: eval \"$(turnstile env)\""
            )]
        }
        var shadowed: [String] = []
        var missing: [String] = []
        for name in names {
            guard let real = Resolver.realBinary(name, path: path, shimsDir: paths.shims, selfPath: executablePath()) else {
                missing.append(name)
                continue
            }
            let realDir = Resolver.canonical((real as NSString).deletingLastPathComponent)
            if let realIndex = dirs.firstIndex(of: realDir), let shimIndex = dirs.firstIndex(of: shimsDir), realIndex < shimIndex {
                shadowed.append("\(name) (\(real))")
            }
        }
        if shadowed.isEmpty {
            findings.append(Finding(level: .ok, topic: "PATH", text: "shims come first for all \(names.count) tools"))
        } else {
            findings.append(Finding(
                level: .problem, topic: "PATH", text: "found before the shims, so not gated: \(shadowed.joined(separator: ", "))",
                fix: "something reorders PATH after turnstile's block; run `turnstile init` again, or move its block to the end of your shell rc"
            ))
        }
        if !missing.isEmpty {
            findings.append(Finding(level: .note, topic: "tools", text: "not installed, shims pass through: \(missing.joined(separator: " "))"))
        }
        return findings
    }

    static func switches(paths: Paths, environment: [String: String]) -> [Finding] {
        var findings: [Finding] = []
        if paths.isDisabled {
            findings.append(Finding(level: .problem, topic: "enabled", text: "turned off with `turnstile disable`; every command runs ungated", fix: "turnstile enable"))
        }
        if environment["TURNSTILE_DISABLE"] == "1" {
            findings.append(Finding(level: .note, topic: "enabled", text: "TURNSTILE_DISABLE=1 in this shell; commands here run ungated"))
        }
        if environment["TURNSTILE_MEMORY_LEVEL_FILE"] != nil {
            findings.append(Finding(level: .note, topic: "memory", text: "TURNSTILE_MEMORY_LEVEL_FILE overrides real memory readings (meant for tests)"))
        }
        return findings
    }

    static func configuration() -> [Finding] {
        let problems = ConfigCommand.problems()
        guard problems.isEmpty else {
            return problems.map { Finding(level: .problem, topic: "config", text: $0, fix: nil) }
                + [Finding(level: .note, topic: "config", text: "`turnstile config` shows the settings in effect")]
        }
        let files = ConfigCommand.files().filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
        return [Finding(level: .ok, topic: "config", text: files.isEmpty ? "defaults (no config files)" : "valid: \(files.joined(separator: ", "))")]
    }

    /// Starts the daemon if needed, so a broken daemon shows up here rather than on the next build.
    static func daemon(paths: Paths) -> [Finding] {
        guard let client = Client.connectOrStart(paths: paths) else {
            if Sandbox.isActive {
                return [Finding(
                    level: .problem, topic: "daemon", text: "this shell is sandboxed and can't reach the daemon on \(paths.socket), so commands here run ungated",
                    fix: "let the agent's sandbox connect to that unix socket (for Codex, that may mean network access), and run `turnstile doctor` once outside the sandbox to start the daemon"
                )]
            }
            return [Finding(level: .problem, topic: "daemon", text: "can't start or reach the daemon on \(paths.socket)", fix: "check \(paths.daemonLog); gated commands run ungated until this is fixed")]
        }
        guard let reply = client.roundTrip(Message(type: "status")), let status = reply.status else {
            return [Finding(level: .problem, topic: "daemon", text: "the daemon isn't answering", fix: "turnstile stop, then run any gated command")]
        }
        guard status.version == Turnstile.version else {
            let busy = !status.running.isEmpty || !status.queued.isEmpty
            return [Finding(
                level: .problem, topic: "daemon", text: "pid \(status.daemonPid) is running version \(status.version ?? "0.1"), not \(Turnstile.version)",
                fix: busy ? "run `turnstile stop` once its jobs finish" : "turnstile stop"
            )]
        }
        return [Finding(level: .ok, topic: "daemon", text: "pid \(status.daemonPid), \(status.running.count) running, \(status.queued.count) queued")]
    }

    static func ungated(paths: Paths, environment: [String: String]) -> [Finding] {
        guard let text = UngatedLog.describe(UngatedLog.read(paths.ungatedLog), now: Date().timeIntervalSince1970, home: homeDirectory(environment)) else { return [] }
        return [Finding(level: .note, topic: "ungated", text: text, fix: "the full list is in \(paths.ungatedLog)")]
    }

    static func system(environment: [String: String], config: Config) -> [Finding] {
        var findings: [Finding] = []
        let reading = MemoryReading.now(environment: environment)
        findings.append(Finding(level: .ok, topic: "memory", text: "\(reading.level)% free of \(Bytes.format(SystemMemory.physical)), pressure \(reading.pressure.name), swap \(Bytes.format(reading.swapUsed)) used"))
        if !FileManager.default.isExecutableFile(atPath: Supervisor.taskpolicy) {
            findings.append(Finding(level: .note, topic: "priority", text: "\(Supervisor.taskpolicy) is missing; agent jobs run at normal priority"))
        }
        let interactive = isatty(0) == 1 && isatty(1) == 1
        let agent = Agent.isAgent(environment: environment, extraMarkers: config.machine.agentEnv ?? [], interactive: interactive)
        findings.append(Finding(level: .ok, topic: "caller", text: agent
            ? "this shell counts as an agent: background priority, queued behind people, pausable"
            : "this shell counts as a person: normal priority, ahead of agents"))
        return findings
    }
}
