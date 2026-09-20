import Darwin
import Foundation
import TurnstileCore

/// `turnstile config`: where settings live, what they resolve to, and whether they're valid.
enum ConfigCommand {
    static let usage = """
        Usage:
          turnstile config [show]            effective settings for this directory, and where they came from
          turnstile config check             validate the global config and this project's .turnstilerc
          turnstile config path [--project]  print the config file's path
          turnstile config init [--project]  create a starter file if there isn't one
          turnstile config edit [--project]  open the file in $EDITOR, then check it
        """

    static func main(_ args: [String]) -> Never {
        let project = args.contains("--project")
        switch args.first(where: { !$0.hasPrefix("-") }) ?? "show" {
        case "show": show()
        case "check": exit(check(printOK: true) ? 0 : 1)
        case "path": print(path(project: project)); exit(0)
        case "init":
            let file = path(project: project)
            if create(file, project: project) { print("Created \(file)") } else { print("\(file) already exists") }
            exit(0)
        case "edit": edit(project: project)
        case "help": print(usage); exit(0)
        case let other:
            warn("unknown config command \(other)\n\n\(usage)")
            exit(64)
        }
    }

    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var cwd: String { FileManager.default.currentDirectoryPath }

    /// The project file in effect, or where a new one would go: the git root, else this directory.
    static func path(project: Bool) -> String {
        guard project else { return ConfigLoader.globalPath(environment: environment) }
        if let existing = ConfigLoader.findProjectFile(from: cwd) { return existing }
        return Workspace.inspect(cwd: cwd, argv: []).root + "/" + ConfigLoader.projectFileName
    }

    static func files() -> [(path: String, scope: ConfigScope)] {
        var result: [(String, ConfigScope)] = [(ConfigLoader.globalPath(environment: environment), .global)]
        if let project = ConfigLoader.findProjectFile(from: cwd) { result.append((project, .project)) }
        return result
    }

    /// Problems in each config file, as printable lines. Empty when everything is valid.
    static func problems() -> [String] {
        var lines: [String] = []
        for (path, scope) in files() {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            do { _ = try ConfigFile.decode(data) } catch {
                lines.append("\(ConfigError(path: path, underlying: error)) (the whole file is ignored)")
                continue
            }
            lines += ConfigLint.warnings(data, scope: scope).map { "\(path): \($0)" }
        }
        return lines
    }

    static func check(printOK: Bool) -> Bool {
        let found = problems()
        for line in found { print(line) }
        if found.isEmpty && printOK {
            let checked = files().filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
            print(checked.isEmpty ? "no config files; using defaults" : "ok: \(checked.joined(separator: ", "))")
        }
        return found.isEmpty
    }

    static func show() -> Never {
        let config: Config
        do { config = try ConfigLoader.load(cwd: cwd, environment: environment) } catch {
            warn("\(error)")
            exit(1)
        }
        let globalPath = ConfigLoader.globalPath(environment: environment)
        let machine = config.machine
        let cpus = SystemMemory.cpuCount
        var lines: [String] = []
        lines.append("global:  \(tilde(globalPath))\(FileManager.default.fileExists(atPath: globalPath) ? "" : " (not found, using defaults)")")
        lines.append("project: \(config.projectRoot.map { tilde($0 + "/" + ConfigLoader.projectFileName) } ?? "none")")
        lines.append("")
        lines.append("machine:")
        let slots = ResourceClass.allCases.map { "\($0.rawValue) \(machine.concurrencyLimit(for: $0, cpuCount: cpus))" }
        lines.append("  concurrency   \(slots.joined(separator: ", "))")
        lines.append("  reserve       keep \(Bytes.format(machine.reserveBytes)) free for everything else")
        lines.append("  pressure      pause agent jobs below \(machine.pauseBelowPercent)% free, resume above \(machine.resumeAbovePercent)%")
        lines.append("  shims         \(CLI.shimNames(config: machine).joined(separator: " "))")
        if let extra = machine.agentEnv, !extra.isEmpty { lines.append("  agentEnv      \(extra.joined(separator: " "))") }

        let throttle = config.throttle
        lines.append("")
        lines.append("throttle\(config.projectRoot == nil ? "" : " (this project)"):")
        lines.append("  inject        \(throttle.inject ?? true ? "on" : "off")")
        lines.append("  jobs          \(throttle.jobs.map(String.init) ?? "auto, lowered under memory pressure")")
        lines.append("  nodeHeap      \(throttle.nodeHeap.map(Bytes.format) ?? "auto, capped under memory pressure")")
        if let hard = throttle.maxMemory {
            lines.append("  kill above    \(Bytes.format(hard)), whatever the machine is doing")
        } else {
            lines.append("  runaway above \(formatMultiplier(throttle.killMultiplier ?? 3))× a command's high-water peak, "
                + "at least \(machine.killFloorPercent)% of RAM (75% before there's history)")
            lines.append("  kill above    only under \(machine.pauseBelowPercent)% free, and only after a pause doesn't help")
        }
        lines.append("  pause         \(throttle.pause ?? true ? "agent jobs may be paused" : "never paused")")

        let commands = (config.global.commands ?? [:]).merging(config.project?.commands ?? [:]) { $1 }
        let scripts = (config.global.scripts ?? [:]).merging(config.project?.scripts ?? [:]) { $1 }
        if !commands.isEmpty || !scripts.isEmpty {
            lines.append("")
            lines.append("rules:")
            for (key, rule) in commands.sorted(by: { $0.key < $1.key }) { lines.append("  \(key)  \(describe(rule))") }
            for (key, rule) in scripts.sorted(by: { $0.key < $1.key }) { lines.append("  script \(key)  \(describe(rule))") }
        }

        let found = problems()
        if !found.isEmpty {
            lines.append("")
            lines.append("problems:")
            lines += found.map { "  \($0)" }
        }
        print(lines.joined(separator: "\n"))
        exit(0)
    }

    static func describe(_ rule: CommandRule) -> String {
        switch rule {
        case .pass: return "pass through"
        case let .gate(cls, memory):
            return [cls?.rawValue ?? "gate", memory.map { "~\(Bytes.format($0))" }].compactMap { $0 }.joined(separator: ", ")
        }
    }

    static func formatMultiplier(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    static func tilde(_ path: String) -> String {
        let home = homeDirectory(environment)
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static let schemaBase = "https://raw.githubusercontent.com/mcclowes/turnstile/main/schema/"

    static func template(project: Bool) -> String {
        if project {
            return """
                {
                  "$schema": "\(schemaBase)turnstilerc.schema.json",
                  "//": "turnstile settings for this project. Every key is optional. See `turnstile config` and https://github.com/mcclowes/turnstile#configuration",
                  "commands": {},
                  "scripts": {},
                  "throttle": {}
                }

                """
        }
        return """
            {
              "$schema": "\(schemaBase)config.schema.json",
              "//": "turnstile settings for this machine. Every key is optional. See `turnstile config` and https://github.com/mcclowes/turnstile#configuration",
              "concurrency": {},
              "commands": {},
              "scripts": {},
              "throttle": {}
            }

            """
    }

    /// Writes the starter file. False if one already exists.
    static func create(_ file: String, project: Bool) -> Bool {
        guard !FileManager.default.fileExists(atPath: file) else { return false }
        do {
            try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try template(project: project).write(toFile: file, atomically: true, encoding: .utf8)
            return true
        } catch {
            warn("can't write \(file): \(error)")
            exit(1)
        }
    }

    static func edit(project: Bool) -> Never {
        let file = path(project: project)
        _ = create(file, project: project)
        let editor = environment["VISUAL"] ?? environment["EDITOR"] ?? "vi"
        let status = runShell("\(editor) \"$1\"", file)
        guard status == 0 else { exit(status) }
        exit(check(printOK: true) ? 0 : 1)
    }

    /// Runs `script` with /bin/sh on the terminal, passing `argument` as $1, and returns its exit status.
    static func runShell(_ script: String, _ argument: String) -> Int32 {
        guard let pid = spawn(path: "/bin/sh", argv: ["sh", "-c", script, "sh", argument], environment: environment, closeOthers: false) else {
            warn("can't start /bin/sh")
            return 1
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}
