import Foundation

public struct Classification: Equatable, Sendable {
    public var resourceClass: ResourceClass
    /// Stable name for learning costs, e.g. "swift test", "npm run test".
    public var key: String
    /// Memory estimate from config, if any.
    public var memory: UInt64?

    public init(_ resourceClass: ResourceClass, key: String, memory: UInt64? = nil) {
        self.resourceClass = resourceClass
        self.key = key
        self.memory = memory
    }
}

public struct ClassifierContext: Sendable {
    public var config: Config
    /// Whether stdin and stdout are terminals; decides watch modes.
    public var interactive: Bool

    public init(config: Config = Config(), interactive: Bool = false) {
        self.config = config
        self.interactive = interactive
    }
}

/// Built-in table of heavy commands. Returns nil to pass a command straight through.
public enum Classifier {
    public static let defaultShims = [
        "swift", "xcodebuild", "cargo", "go", "gradle", "make",
        "npm", "pnpm", "yarn", "bun", "npx",
        "vitest", "jest", "playwright", "tsc", "xcrun", "corepack",
    ]

    static let nodeRunners: Set<String> = ["npm", "pnpm", "yarn", "bun"]

    public static func classify(tool: String, args: [String], context: ClassifierContext = ClassifierContext()) -> Classification? {
        if let rule = context.config.commandRule(for: [tool] + args) {
            let builtIn = builtIn(tool: tool, args: args, context: context)
            switch rule {
            case .pass: return nil
            case let .gate(cls, memory):
                let resolved = cls ?? builtIn?.resourceClass ?? .compile
                return Classification(resolved, key: builtIn?.key ?? tool, memory: memory)
            }
        }
        return builtIn(tool: tool, args: args, context: context)
    }

    static func builtIn(tool: String, args: [String], context: ClassifierContext) -> Classification? {
        if isQuickQuery(args) { return nil }
        switch tool {
        case "swift": return swift(args)
        case "xcodebuild": return xcodebuild(args)
        case "cargo": return cargo(args)
        case "go": return go(args)
        case "gradle", "gradlew": return gradle(tool, args)
        case "make", "gmake": return make(tool, args)
        case "npm", "pnpm", "yarn", "bun": return nodeRunner(tool, args, context: context)
        case "npx": return exec(tool: tool, args, valueFlags: ["-p", "--package", "-c", "--call"], context: context)
        case "vitest": return vitest(args, context: context)
        case "jest": return jest(args)
        case "playwright": return firstPositional(args) == "test" ? Classification(.browser, key: "playwright test") : nil
        case "cypress": return firstPositional(args) == "run" ? Classification(.browser, key: "cypress run") : nil
        case "tsc": return args.contains(where: { ["-w", "--watch", "--init"].contains($0) }) ? nil : Classification(.compile, key: "tsc")
        case "xcrun": return xcrun(args, context: context)
        case "corepack": return corepack(args, context: context)
        default: return nil
        }
    }

    static func isQuickQuery(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        return ["--version", "-version", "-V", "--help", "-help", "-h"].contains(first)
    }

    /// First argument that isn't a flag, skipping the values of flags that take one.
    static func firstPositional(_ args: [String], valueFlags: Set<String> = [], skip: (String) -> Bool = { _ in false }) -> String? {
        positionals(args, valueFlags: valueFlags, skip: skip).first
    }

    static func positionals(_ args: [String], valueFlags: Set<String> = [], skip: (String) -> Bool = { _ in false }) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" { result += args[(index + 1)...]; break }
            if valueFlags.contains(arg) { index += 2; continue }
            if !arg.hasPrefix("-") && !skip(arg) { result.append(arg) }
            index += 1
        }
        return result
    }

    static func positionalIndex(_ args: [String], valueFlags: Set<String>) -> Int? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if valueFlags.contains(arg) { index += 2; continue }
            if !arg.hasPrefix("-") { return index }
            index += 1
        }
        return nil
    }

    // MARK: Tools

    static func swift(_ args: [String]) -> Classification? {
        switch args.first {
        case "build": return Classification(.compile, key: "swift build" + configuration(args, flags: ["-c", "--configuration"], default: "debug"))
        case "test": return Classification(.test, key: "swift test" + configuration(args, flags: ["-c", "--configuration"], default: "debug"))
        default: return nil  // run, package, format, repl, scripts
        }
    }

    /// `xcrun swift build` finds its tool through the developer dir, not PATH, so it would otherwise skip the shims.
    /// Classifies the tool it runs; lookups like `--find` and `--show-sdk-path` pass through.
    static func xcrun(_ args: [String], context: ClassifierContext) -> Classification? {
        let valueFlags: Set<String> = ["--sdk", "-sdk", "--toolchain", "-toolchain"]
        var index = 0
        while index < args.count {
            let arg = args[index]
            if valueFlags.contains(arg) { index += 2; continue }
            if arg.hasPrefix("-") {
                if arg == "-f" || arg == "--find" || arg.hasPrefix("--show-") { return nil }
                index += 1
                continue
            }
            return classify(tool: (arg as NSString).lastPathComponent, args: Array(args[(index + 1)...]), context: context)
        }
        return nil
    }

    /// `corepack pnpm test` runs a package manager that corepack fetched, bypassing the shims for it.
    static func corepack(_ args: [String], context: ClassifierContext) -> Classification? {
        guard let first = args.first, !first.hasPrefix("-") else { return nil }
        let manager = first.split(separator: "@").first.map(String.init) ?? first
        guard manager == "npm" || nodeRunners.contains(manager) || manager == "npx" else { return nil }
        return classify(tool: manager, args: Array(args.dropFirst()), context: context)
    }

    static func xcodebuild(_ args: [String]) -> Classification? {
        let queries: Set<String> = [
            "-list", "-showsdks", "-showBuildSettings", "-showdestinations", "-showTestPlans",
            "-usage", "-license", "-checkFirstLaunchStatus", "-runFirstLaunch",
            "-resolvePackageDependencies", "-downloadPlatform", "-downloadAllPlatforms", "-exportArchive",
            "-exportLocalizations", "-importLocalizations", "-find", "-find-executable", "-find-library",
        ]
        if args.contains(where: queries.contains) { return nil }
        if args.contains("test") || args.contains("test-without-building") {
            return Classification(.test, key: "xcodebuild test" + configuration(args, flags: ["-configuration"], default: "Debug"))
        }
        if args.contains("clean") && !args.contains("build") { return nil }
        return Classification(.compile, key: "xcodebuild build" + configuration(args, flags: ["-configuration"], default: "Debug"))
    }

    static func cargo(_ args: [String]) -> Classification? {
        let sub = firstPositional(args, valueFlags: ["-C", "--config", "-Z", "--color"], skip: { $0.hasPrefix("+") })
        switch sub {
        case "build", "b", "check", "c", "clippy", "doc", "d", "install", "rustc", "rustdoc", "fix":
            return Classification(.compile, key: "cargo \(canonical(sub!, ["b": "build", "c": "check", "d": "doc"]))" + cargoProfile(args))
        case "test", "t", "bench", "nextest", "miri":
            return Classification(.test, key: "cargo \(canonical(sub!, ["t": "test"]))" + cargoProfile(args))
        default: return nil
        }
    }

    static func go(_ args: [String]) -> Classification? {
        switch firstPositional(args, valueFlags: ["-C"]) {
        case "build", "install", "vet": return Classification(.compile, key: "go \(firstPositional(args, valueFlags: ["-C"])!)")
        case "test": return Classification(.test, key: "go test")
        default: return nil
        }
    }

    static func gradle(_ tool: String, _ args: [String]) -> Classification? {
        let passFlags: Set<String> = ["-v", "--stop", "--status", "--help", "-?"]
        if args.contains(where: passFlags.contains) { return nil }
        let tasks = positionals(args, valueFlags: ["-p", "--project-dir", "-b", "--build-file", "-c", "--settings-file", "-x", "--exclude-task", "-I", "--init-script", "-g", "--gradle-user-home", "--console", "--warning-mode", "--priority", "-D", "-P"])
        let queryTasks: Set<String> = ["tasks", "help", "dependencies", "properties", "projects", "wrapper", "init", "clean"]
        if !tasks.isEmpty && tasks.allSatisfy(queryTasks.contains) { return nil }
        if tasks.contains(where: { $0.lowercased().contains("test") || $0.hasSuffix("check") }) {
            return Classification(.test, key: "gradle test")
        }
        return Classification(.compile, key: "gradle build")
    }

    static func make(_ tool: String, _ args: [String]) -> Classification? {
        let passFlags: Set<String> = ["-n", "--dry-run", "--just-print", "-q", "--question", "-p", "--print-data-base", "-v"]
        if args.contains(where: passFlags.contains) { return nil }
        let targets = positionals(args, valueFlags: ["-C", "-f", "--file", "-I", "-o", "-W", "--directory"], skip: { $0.contains("=") || Int($0) != nil })
        let quiet: Set<String> = ["clean", "distclean", "help", "install", "fmt", "format", "lint-fix"]
        if !targets.isEmpty && targets.allSatisfy(quiet.contains) { return nil }
        if targets.contains(where: { $0.contains("test") || $0.contains("check") }) {
            return Classification(.test, key: "make test")
        }
        return Classification(.compile, key: targets.isEmpty ? "make" : "make \(targets.joined(separator: " "))")
    }

    static func vitest(_ args: [String], context: ClassifierContext) -> Classification? {
        if args.contains(where: { $0 == "--watch" || $0 == "-w" || $0 == "--ui" }) { return nil }
        switch firstPositional(args, valueFlags: ["--config", "-c", "--root", "-r", "--project", "--dir", "--reporter", "--environment", "--pool", "-t", "--testNamePattern"]) {
        case "run", "related", "bench": return Classification(.test, key: "vitest run")
        case "watch", "dev", "list", "init": return nil
        default:
            if args.contains("--run") { return Classification(.test, key: "vitest run") }
            // Without `run`, vitest watches in a terminal and runs once elsewhere.
            return context.interactive ? nil : Classification(.test, key: "vitest run")
        }
    }

    static func jest(_ args: [String]) -> Classification? {
        let pass: Set<String> = ["--watch", "--watchAll", "--listTests", "--showConfig", "--init", "--clearCache"]
        if args.contains(where: pass.contains) { return nil }
        return Classification(.test, key: "jest")
    }

    // MARK: Package managers

    static let npmBuiltins: Set<String> = [
        "install", "i", "ci", "add", "uninstall", "remove", "rm", "update", "up", "upgrade", "outdated", "ls", "list",
        "why", "explain", "link", "ln", "unlink", "publish", "pack", "version", "view", "info", "show", "init", "create",
        "config", "set", "get", "cache", "store", "prune", "dedupe", "ddp", "audit", "fund", "doctor", "login", "logout",
        "whoami", "search", "root", "bin", "prefix", "env", "setup", "patch", "patch-commit", "licenses", "fetch", "import",
        "rebuild", "rb", "server", "deploy", "self-update", "approve-builds", "workspaces", "workspace", "plugin", "npm",
        "constraints", "dlx", "x", "exec", "node", "help", "outdated", "owner", "team", "token", "access", "profile",
        "completion", "edit", "explore", "repo", "docs", "bugs", "hook", "org", "ping", "restart", "stop", "shrinkwrap",
        "star", "stars", "unstar", "unpublish", "deprecate", "dist-tag", "pkg", "query", "sbom", "diff", "install-test",
        "it", "install-ci-test", "cit", "upgrade-interactive", "why", "catalog", "pm", "outdated",
    ]

    static let runnerValueFlags: Set<String> = ["--filter", "-F", "--dir", "-C", "--prefix", "-w", "--workspace", "--cwd", "--loglevel"]

    static func nodeRunner(_ tool: String, _ args: [String], context: ClassifierContext) -> Classification? {
        let valueFlags = tool == "npm" ? runnerValueFlags : runnerValueFlags.subtracting(["-w"])
        guard let index = positionalIndex(args, valueFlags: valueFlags) else { return nil }
        let sub = args[index]
        let rest = Array(args[(index + 1)...])

        switch sub {
        case "test", "t", "tst":
            if tool == "bun" && sub == "test" { return Classification(.test, key: "bun test") }
            return script("test", tool: tool, args: rest, context: context)
        case "run", "run-script", "rum", "urn":
            guard let name = firstPositional(rest) else { return nil }
            return script(name, tool: tool, args: rest, context: context)
        case "exec", "x", "dlx":
            return exec(tool: "\(tool) \(sub)", rest, valueFlags: ["-p", "--package", "-c"], context: context)
        case "build" where tool == "bun":
            return Classification(.compile, key: "bun build")
        default:
            // pnpm, yarn, and bun run scripts by bare name; npm doesn't.
            if tool == "npm" || npmBuiltins.contains(sub) { return nil }
            if tool == "bun" && (sub.contains(".") || sub.contains("/")) { return nil }  // `bun file.ts`
            return script(sub, tool: tool, args: rest, context: context)
        }
    }

    /// Classifies a package.json script by name.
    static func script(_ name: String, tool: String, args: [String], context: ClassifierContext) -> Classification? {
        let key = "\(tool) run \(name)"
        if let rule = context.config.scriptRule(for: name) {
            switch rule {
            case .pass: return nil
            case let .gate(cls, memory):
                return Classification(cls ?? scriptClass(name) ?? .compile, key: key, memory: memory)
            }
        }
        if args.contains(where: { $0 == "--watch" || $0 == "-w" }) { return nil }
        return scriptClass(name).map { Classification($0, key: key) }
    }

    public static func scriptClass(_ name: String) -> ResourceClass? {
        let words = Set(name.lowercased().split(whereSeparator: { ":-_.".contains($0) }).map(String.init))
        let pass: Set<String> = ["dev", "start", "serve", "watch", "preview", "storybook", "open", "ui"]
        if !words.isDisjoint(with: pass) { return nil }
        if !words.isDisjoint(with: ["e2e", "playwright", "cypress", "browser", "visual"]) { return .browser }
        if !words.isDisjoint(with: ["test", "tests", "spec", "vitest", "jest", "coverage", "ci", "check"]) { return .test }
        if !words.isDisjoint(with: ["build", "compile", "typecheck", "tsc", "lint", "bundle", "package", "dist"]) { return .compile }
        return nil
    }

    /// `npx vitest run`, `pnpm exec jest`: classify the command being run.
    static func exec(tool: String, _ args: [String], valueFlags: Set<String>, context: ClassifierContext) -> Classification? {
        guard let index = positionalIndex(args, valueFlags: valueFlags) else { return nil }
        var inner = args[index]
        if let at = inner.lastIndex(of: "@"), at != inner.startIndex { inner = String(inner[..<at]) }  // vitest@3
        inner = (inner as NSString).lastPathComponent
        let rest = Array(args[(index + 1)...])
        if nodeRunners.contains(inner) || inner == "npx" { return nil }
        return classify(tool: inner, args: rest, context: context)
    }

    /// " -c release" for a non-default build configuration, so its history stays apart from debug builds.
    static func configuration(_ args: [String], flags: [String], default fallback: String) -> String {
        guard let (flag, value) = flagValue(args, flags), value != fallback else { return "" }
        return " \(flag) \(value)"
    }

    static func cargoProfile(_ args: [String]) -> String {
        if let (_, profile) = flagValue(args, ["--profile"]), profile != "dev" { return " --profile \(profile)" }
        return args.contains("--release") || args.contains("-r") ? " --release" : ""
    }

    /// The last value given for any of these flags, as `-c release` or `-c=release`.
    static func flagValue(_ args: [String], _ flags: [String]) -> (flag: String, value: String)? {
        var found: (String, String)?
        for (index, arg) in args.enumerated() {
            if flags.contains(arg), index + 1 < args.count {
                found = (arg, args[index + 1])
            } else if let flag = flags.first(where: { arg.hasPrefix($0 + "=") }) {
                found = (flag, String(arg.dropFirst(flag.count + 1)))
            }
        }
        return found
    }

    static func canonical(_ word: String, _ aliases: [String: String]) -> String {
        aliases[word] ?? word
    }
}
