import Darwin
import Foundation
import TurnstileCore

enum CLI {
    static let version = Turnstile.version

    static let usage = """
        turnstile: a machine-wide, memory-aware gate for builds and tests

        Usage:
          turnstile init [--shell zsh|bash|fish] [--no-rc]   install shims and add them to PATH
          turnstile doctor                                   check the install, PATH, config, and daemon
          turnstile status [--json] [--watch]                running and queued jobs, memory, recent runs
          turnstile bump <job>                               move a job (number, pid, or name) to the front
          turnstile run [--class compile|test|browser] -- <command>   gate any command
          turnstile classify <command>                       show how a command would be gated
          turnstile config [show|check|path|init|edit]       see, validate, and edit settings
          turnstile env [--shell zsh|bash|fish]              print the PATH setup, for terminal managers
          turnstile shims                                    rebuild the shims directory
          turnstile disable | enable                         turn gating off and on for every shell
          turnstile stop                                     stop the daemon
          turnstile uninstall                                remove shims and PATH setup
          turnstile daemon                                   run the scheduler in the foreground

        Config: ~/.config/turnstile/config.json, and .turnstilerc in any project.
        """

    static func main(_ args: [String]) -> Never {
        let command = args.first ?? "help"
        let rest = Array(args.dropFirst())
        if command != "run", let first = rest.first, ["--help", "-h", "help"].contains(first) {
            print(command == "config" ? ConfigCommand.usage : usage)
            exit(0)
        }
        switch command {
        case "init": initialize(rest)
        case "status": status(rest)
        case "bump": bump(rest)
        case "run": run(rest)
        case "classify": classify(rest)
        case "config": ConfigCommand.main(rest)
        case "doctor": Doctor.main(rest)
        case "disable": setEnabled(false)
        case "enable": setEnabled(true)
        case "env": env(rest)
        case "shims", "rehash": rebuildShims(announce: true); exit(0)
        case "stop": stop()
        case "uninstall": uninstall()
        case "daemon": daemon(rest)
        case "--version", "-v", "version": print(version); exit(0)
        case "help", "--help", "-h": print(usage); exit(0)
        default:
            warn("unknown command \(command)\n\n\(usage)")
            exit(64)
        }
    }

    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var paths: Paths { Paths(environment: environment) }

    static func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    // MARK: init / env / shims / uninstall

    static func initialize(_ args: [String]) -> Never {
        let paths = self.paths
        do { try paths.ensure() } catch {
            warn("can't create \(paths.home): \(error)")
            exit(1)
        }
        guard installBinary(paths: paths) else { exit(1) }
        rebuildShims(announce: false)
        print("Installed shims in \(paths.shims)")
        retireOldDaemon(paths: paths)

        if args.contains("--no-rc") {
            print("Skipped shell startup files. Put \(paths.shims) first on PATH, or run: eval \"$(turnstile env)\"")
            exit(0)
        }
        let shell = option("--shell", in: args).flatMap(ShellSetup.Shell.init(rawValue:)) ?? .detect(environment)
        let snippet = ShellSetup.snippet(shell: shell, shimsDir: paths.shims)
        let home = homeDirectory(environment)
        for file in shell.startupFiles {
            let path = home + "/" + file
            let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let updated = ShellSetup.install(snippet, into: existing)
            guard updated != existing else { continue }
            do {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try updated.write(toFile: path, atomically: true, encoding: .utf8)
                print("Updated ~/\(file)")
            } catch {
                warn("can't update \(path): \(error)")
            }
        }
        print("Open a new shell (or run: eval \"$(turnstile env)\"), then check it with: turnstile doctor")
        exit(0)
    }

    /// Copies this binary into the turnstile home, so shims don't point into a build folder.
    static func installBinary(paths: Paths) -> Bool {
        guard let me = executablePath() else {
            warn("can't find my own executable")
            return false
        }
        let target = paths.bin + "/turnstile"
        if Resolver.canonical(target) == me { return true }
        do {
            try FileManager.default.createDirectory(atPath: paths.bin, withIntermediateDirectories: true)
            let staging = target + ".new"
            try? FileManager.default.removeItem(atPath: staging)
            try FileManager.default.copyItem(atPath: me, toPath: staging)
            _ = rename(staging, target)
            return true
        } catch {
            warn("can't install to \(target): \(error)")
            return false
        }
    }

    /// A daemon from an earlier version keeps running until idle; stop it now if that costs nothing.
    static func retireOldDaemon(paths: Paths) {
        guard let client = Client.connect(socketPath: paths.socket),
              let status = client.roundTrip(Message(type: "status"))?.status,
              status.version != Turnstile.version else { return }
        if status.running.isEmpty && status.queued.isEmpty {
            _ = client.roundTrip(Message(type: "stop"))
            print("Stopped the old daemon; the next gated command starts the new one")
        } else {
            print("An older daemon is still running jobs; run `turnstile stop` once they finish")
        }
    }

    static func setEnabled(_ enabled: Bool) -> Never {
        let paths = self.paths
        if enabled {
            try? FileManager.default.removeItem(atPath: paths.disabledFlag)
            print("turnstile is on: heavy commands are gated again")
        } else {
            try? paths.ensure()
            FileManager.default.createFile(atPath: paths.disabledFlag, contents: Data())
            print("turnstile is off: every command runs ungated until `turnstile enable`")
        }
        exit(0)
    }

    static func shimNames(config: MachineConfig) -> [String] {
        var names = Classifier.defaultShims + (config.shims?.add ?? [])
        let removed = Set(config.shims?.remove ?? [])
        names.removeAll { removed.contains($0) }
        return Array(NSOrderedSet(array: names)) as? [String] ?? names
    }

    static func rebuildShims(announce: Bool) {
        let paths = self.paths
        try? paths.ensure()
        let target = FileManager.default.fileExists(atPath: paths.bin + "/turnstile") ? paths.bin + "/turnstile" : (executablePath() ?? "")
        let config = Supervisor.loadConfig(environment: environment)
        let names = shimNames(config: config.machine) + ["turnstile"]
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: paths.shims)) ?? []
        for name in existing where !names.contains(name) {
            try? FileManager.default.removeItem(atPath: paths.shims + "/" + name)
        }
        // Swap each link in with rename(2), so a command started mid-rebuild never finds its shim missing.
        for name in names {
            let link = paths.shims + "/" + name
            let staging = link + ".new"
            try? FileManager.default.removeItem(atPath: staging)
            do {
                try FileManager.default.createSymbolicLink(atPath: staging, withDestinationPath: target)
                guard Darwin.rename(staging, link) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } catch {
                warn("can't create \(link): \(error)")
            }
        }
        if announce {
            print("Shims for \(names.filter { $0 != "turnstile" }.joined(separator: ", ")) in \(paths.shims)")
            exit(0)
        }
    }

    static func env(_ args: [String]) -> Never {
        let shell = option("--shell", in: args).flatMap(ShellSetup.Shell.init(rawValue:)) ?? .detect(environment)
        let lines = ShellSetup.snippet(shell: shell, shimsDir: paths.shims).split(separator: "\n")
        print(lines.dropFirst().dropLast().joined(separator: "\n"))
        exit(0)
    }

    static func uninstall() -> Never {
        let home = homeDirectory(environment)
        for shell in ShellSetup.Shell.allCases {
            for file in shell.startupFiles {
                let path = home + "/" + file
                guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let updated = ShellSetup.remove(from: existing)
                guard updated != existing else { continue }
                if updated.isEmpty && shell == .fish {
                    try? FileManager.default.removeItem(atPath: path)
                } else {
                    try? updated.write(toFile: path, atomically: true, encoding: .utf8)
                }
                print("Updated ~/\(file)")
            }
        }
        if let client = Client.connect(socketPath: paths.socket) { _ = client.roundTrip(Message(type: "stop")) }
        try? FileManager.default.removeItem(atPath: paths.shims)
        try? FileManager.default.removeItem(atPath: paths.bin)
        print("Removed \(paths.shims). History is kept in \(paths.database).")
        exit(0)
    }

    // MARK: status / bump / stop

    static func status(_ args: [String]) -> Never {
        let json = args.contains("--json")
        guard args.contains("--watch") || args.contains("-w") else {
            print(statusText(json: json))
            exit(0)
        }
        // Redraw in place until Ctrl-C.
        while true {
            let text = statusText(json: json)
            print("\u{1B}[H\u{1B}[2J" + text + "\n\n(refreshing every second; Ctrl-C to stop)")
            fflush(stdout)
            sleep(1)
        }
    }

    static func statusText(json: Bool) -> String {
        guard let client = Client.connect(socketPath: paths.socket),
              let reply = client.roundTrip(Message(type: "status")), let snapshot = reply.status else {
            if json { return #"{"daemon":false}"# }
            var lines = [
                "turnstile: daemon not running (starts with the first gated command)",
                "memory: \(SystemMemory.level())% free of \(Bytes.format(SystemMemory.physical))",
            ]
            if let store = try? Store(path: paths.database) {
                let recent = store.recent(limit: 10)
                lines.append("")
                lines.append(recent.isEmpty ? StatusFormatter.nothingYet : StatusFormatter.recent(recent))
            }
            return lines.joined(separator: "\n")
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: (try? encoder.encode(snapshot)) ?? Data(), as: UTF8.self)
        }
        return StatusFormatter.render(snapshot, now: Date().timeIntervalSince1970)
    }

    static func bump(_ args: [String]) -> Never {
        guard let target = args.first else {
            warn("usage: turnstile bump <job number | pid | name>")
            exit(64)
        }
        guard let client = Client.connect(socketPath: paths.socket) else {
            warn("daemon not running, nothing to bump")
            exit(1)
        }
        var message = Message(type: "bump")
        message.target = target
        guard let reply = client.roundTrip(message) else {
            warn("no reply from daemon")
            exit(1)
        }
        if reply.type == "error" {
            warn(reply.text ?? "bump failed")
            exit(1)
        }
        print(reply.text ?? "bumped")
        exit(0)
    }

    static func stop() -> Never {
        guard let client = Client.connect(socketPath: paths.socket) else {
            print("daemon not running")
            exit(0)
        }
        _ = client.roundTrip(Message(type: "stop"))
        print("daemon stopped")
        exit(0)
    }

    // MARK: run / classify / daemon

    static func run(_ args: [String]) -> Never {
        let parsed: RunArguments
        do { parsed = try RunArguments.parse(args) } catch RunArguments.Problem.unknownClass(let value) {
            warn("unknown class \(value) (use compile, test, or browser)")
            exit(64)
        } catch {
            warn("usage: turnstile run [--class compile|test|browser] -- <command>")
            exit(64)
        }
        let forced = parsed.forced
        let tool = parsed.command[0]
        let name = (tool as NSString).lastPathComponent
        let environment = self.environment
        let real = tool.contains("/")
            ? tool
            : Resolver.realBinary(tool, path: environment["PATH"] ?? "", shimsDir: paths.shims, selfPath: executablePath())
        guard let real else {
            warn("\(tool): command not found")
            exit(127)
        }
        let rest = Array(parsed.command.dropFirst())
        if Supervisor.insideAdmittedJob(environment) || paths.isDisabled { execReal(real, rest) }
        let interactive = isatty(0) == 1 && isatty(1) == 1
        let config = Supervisor.loadConfig(environment: environment)
        var classification = Classifier.classify(tool: name, args: rest, context: ClassifierContext(config: config, interactive: interactive))
            ?? Classification(forced ?? .compile, key: ([name] + rest.prefix(1)).joined(separator: " "))
        if let forced { classification.resourceClass = forced }
        Supervisor.gate(tool: name, real: real, args: rest, classification: classification, config: config, interactive: interactive)
    }

    static func classify(_ args: [String]) -> Never {
        guard let tool = args.first else {
            warn("usage: turnstile classify <command>")
            exit(64)
        }
        let interactive = isatty(0) == 1 && isatty(1) == 1
        let config = Supervisor.loadConfig(environment: environment)
        let name = (tool as NSString).lastPathComponent
        let context = ClassifierContext(config: config, interactive: interactive)
        guard let result = Classifier.classify(tool: name, args: Array(args.dropFirst()), context: context) else {
            print("pass through")
            exit(0)
        }
        var line = "\(result.resourceClass.rawValue) (\(result.key))"
        if let memory = result.memory { line += ", ~\(Bytes.format(memory)) from config" }
        if let root = config.projectRoot { line += ", using \(root)/\(ConfigLoader.projectFileName)" }
        print(line)
        exit(0)
    }

    static func daemon(_ args: [String]) -> Never {
        let idle = option("--idle-exit", in: args).flatMap(Double.init) ?? 1800
        do {
            try Daemon(paths: paths, idleExit: idle).run()
        } catch {
            warn("daemon failed to start: \(error)")
            exit(1)
        }
    }
}

enum StatusFormatter {
    static let nothingYet = """
        Nothing has gone through turnstile yet. If you've run builds, their shell may not
        have the shims on PATH: run `turnstile doctor` in that shell to check.
        """

    static func render(_ snapshot: StatusSnapshot, now: Double) -> String {
        var lines: [String] = []
        let free = snapshot.physicalMemory / 100 * UInt64(snapshot.memoryLevel)
        let limits = ResourceClass.allCases.map { "\($0.rawValue) \(snapshot.limits[$0.rawValue] ?? 1)" }.joined(separator: ", ")
        lines.append("memory: \(snapshot.memoryLevel)% free (~\(Bytes.format(free)) of \(Bytes.format(snapshot.physicalMemory))), slots: \(limits)")

        lines.append("")
        lines.append(snapshot.running.isEmpty ? "running: none" : "running:")
        for job in snapshot.running {
            var detail = "\(Bytes.format(job.footprint ?? 0)) now"
            if let peak = job.peak { detail += ", peak \(Bytes.format(peak))" }
            detail += ", est ~\(Bytes.format(job.estimate))"
            let elapsed = job.startedAt.map { formatDuration(now - $0) } ?? "-"
            var flags: [String] = []
            if job.agent { flags.append("agent") }
            if job.state != "running" { flags.append(job.state) }
            if job.joiners > 0 { flags.append("+\(job.joiners) joined") }
            lines.append("  #\(job.id)  \(job.resourceClass.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(job.label)  \(detail), \(elapsed)\(flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]")")
        }

        lines.append("")
        lines.append(snapshot.queued.isEmpty ? "queued: none" : "queued:")
        for job in snapshot.queued {
            let waited = formatDuration(now - job.queuedAt)
            lines.append("  #\(job.id)  \(job.resourceClass.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(job.label)  ~\(Bytes.format(job.estimate)), waiting \(waited)\(job.agent ? "  [agent]" : "")")
            if let reason = job.waiting { lines.append("        \(reason)") }
        }
        if !snapshot.recent.isEmpty {
            lines.append("")
            lines.append(recent(snapshot.recent))
        } else if snapshot.running.isEmpty && snapshot.queued.isEmpty {
            lines.append("")
            lines.append(nothingYet)
        }
        return lines.joined(separator: "\n")
    }

    static func recent(_ entries: [HistoryEntry]) -> String {
        var lines = ["recent:"]
        for entry in entries {
            var detail = entry.outcome
            if let code = entry.exitCode, entry.outcome == "failed" { detail += " (\(code))" }
            if let peak = entry.peak { detail += ", peak \(Bytes.format(peak))" }
            if let duration = entry.duration { detail += ", \(formatDuration(duration))" }
            lines.append("  #\(entry.id)  \(entry.project) \(entry.key)  \(detail)")
        }
        return lines.joined(separator: "\n")
    }
}
