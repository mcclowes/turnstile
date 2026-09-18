import Foundation

/// What a command override says to do: gate it under a class, or pass it through.
public enum CommandRule: Equatable, Sendable {
    case pass
    case gate(ResourceClass?, memory: UInt64?)

    public var resourceClass: ResourceClass? {
        if case let .gate(cls, _) = self { return cls }
        return nil
    }

    public var memory: UInt64? {
        if case let .gate(_, memory) = self { return memory }
        return nil
    }
}

extension CommandRule: Decodable {
    private struct Object: Decodable {
        var `class`: String?
        var memory: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let word = try? container.decode(String.self) {
            self = try CommandRule.parse(word: word, memory: nil, decoder: decoder)
            return
        }
        let object = try container.decode(Object.self)
        self = try CommandRule.parse(word: object.class, memory: object.memory, decoder: decoder)
    }

    private static func parse(word: String?, memory: String?, decoder: Decoder) throws -> CommandRule {
        var bytes: UInt64?
        if let memory {
            guard let parsed = Bytes.parse(memory) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad size \"\(memory)\""))
            }
            bytes = parsed
        }
        switch word {
        case "pass", "none", "off": return .pass
        case nil: return .gate(nil, memory: bytes)
        case let word?:
            guard let cls = ResourceClass(rawValue: word) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown class \"\(word)\" (use compile, test, browser, or pass)"))
            }
            return .gate(cls, memory: bytes)
        }
    }
}

/// Throttling knobs (issue #2). Every field is optional so project files can override single values.
public struct ThrottleConfig: Decodable, Equatable, Sendable {
    /// Inject parallelism and heap limits into commands.
    public var inject: Bool?
    /// Fixed parallelism to inject. Default: sized from memory pressure.
    public var jobs: Int?
    /// Node heap cap (`--max-old-space-size`). Default: only under pressure.
    public var nodeHeap: UInt64?
    /// Hard ceiling; a job tree above it is killed.
    public var maxMemory: UInt64?
    /// Kill a job that exceeds this multiple of its usual peak.
    public var killMultiplier: Double?
    /// Allow pausing (SIGSTOP) this project's jobs under memory pressure.
    public var pause: Bool?

    public init(inject: Bool? = nil, jobs: Int? = nil, nodeHeap: UInt64? = nil, maxMemory: UInt64? = nil, killMultiplier: Double? = nil, pause: Bool? = nil) {
        self.inject = inject
        self.jobs = jobs
        self.nodeHeap = nodeHeap
        self.maxMemory = maxMemory
        self.killMultiplier = killMultiplier
        self.pause = pause
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case inject, jobs, nodeHeap, maxMemory, killMultiplier, pause
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inject = try c.decodeIfPresent(Bool.self, forKey: .inject)
        jobs = try c.decodeIfPresent(Int.self, forKey: .jobs)
        nodeHeap = try c.decodeSizeIfPresent(forKey: .nodeHeap)
        maxMemory = try c.decodeSizeIfPresent(forKey: .maxMemory)
        killMultiplier = try c.decodeIfPresent(Double.self, forKey: .killMultiplier)
        pause = try c.decodeIfPresent(Bool.self, forKey: .pause)
    }

    /// Values in `other` win.
    public func merged(with other: ThrottleConfig) -> ThrottleConfig {
        ThrottleConfig(
            inject: other.inject ?? inject,
            jobs: other.jobs ?? jobs,
            nodeHeap: other.nodeHeap ?? nodeHeap,
            maxMemory: other.maxMemory ?? maxMemory,
            killMultiplier: other.killMultiplier ?? killMultiplier,
            pause: other.pause ?? pause
        )
    }
}

/// Machine-wide settings. Only read from the global config; a project can't raise machine limits.
public struct MachineConfig: Decodable, Equatable, Sendable {
    /// Max concurrent jobs per class.
    public var concurrency: [String: Int]?
    /// Memory to keep free for everything else.
    public var reserve: UInt64?
    /// Pause jobs when free memory falls below this percent.
    public var pauseBelow: Int?
    /// Resume paused jobs when free memory rises above this percent.
    public var resumeAbove: Int?
    /// Extra tools to shim, and built-in shims to drop.
    public var shims: ShimConfig?
    /// Extra environment variables that mark a process as an agent.
    public var agentEnv: [String]?

    public init() {}

    enum CodingKeys: String, CodingKey, CaseIterable {
        case concurrency, reserve, pauseBelow, resumeAbove, shims, agentEnv
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        concurrency = try c.decodeIfPresent([String: Int].self, forKey: .concurrency)
        reserve = try c.decodeSizeIfPresent(forKey: .reserve)
        pauseBelow = try c.decodeIfPresent(Int.self, forKey: .pauseBelow)
        resumeAbove = try c.decodeIfPresent(Int.self, forKey: .resumeAbove)
        shims = try c.decodeIfPresent(ShimConfig.self, forKey: .shims)
        agentEnv = try c.decodeIfPresent([String].self, forKey: .agentEnv)
    }

    public func concurrencyLimit(for cls: ResourceClass, cpuCount: Int) -> Int {
        if let limit = concurrency?[cls.rawValue] { return max(1, limit) }
        switch cls {
        case .compile, .test: return max(1, min(4, cpuCount / 4))
        case .browser: return 1
        }
    }

    public var reserveBytes: UInt64 { reserve ?? 2 * Bytes.gb }
    public var pauseBelowPercent: Int { pauseBelow ?? 8 }
    public var resumeAbovePercent: Int { resumeAbove ?? 20 }
}

public struct ShimConfig: Decodable, Equatable, Sendable {
    public var add: [String]?
    public var remove: [String]?
}

/// One config file: the global one or a project `.turnstilerc`.
public struct ConfigFile: Decodable, Equatable, Sendable {
    /// Keys are command prefixes such as "swift test" or "npm run e2e".
    public var commands: [String: CommandRule]?
    /// npm/pnpm/yarn/bun script name to class, e.g. {"e2e": "browser"}.
    public var scripts: [String: CommandRule]?
    public var throttle: ThrottleConfig?
    public var machine: MachineConfig

    public init(commands: [String: CommandRule]? = nil, scripts: [String: CommandRule]? = nil, throttle: ThrottleConfig? = nil, machine: MachineConfig = MachineConfig()) {
        self.commands = commands
        self.scripts = scripts
        self.throttle = throttle
        self.machine = machine
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case commands, scripts, throttle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commands = try c.decodeIfPresent([String: CommandRule].self, forKey: .commands)
        scripts = try c.decodeIfPresent([String: CommandRule].self, forKey: .scripts)
        throttle = try c.decodeIfPresent(ThrottleConfig.self, forKey: .throttle)
        machine = try MachineConfig(from: decoder)
    }

    public static func decode(_ data: Data) throws -> ConfigFile {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return ConfigFile() }
        return try JSONDecoder().decode(ConfigFile.self, from: data)
    }
}

/// Global config with the project's `.turnstilerc` layered on top.
public struct Config: Equatable, Sendable {
    public var global: ConfigFile
    public var project: ConfigFile?
    /// Directory holding the `.turnstilerc`, if any.
    public var projectRoot: String?

    public init(global: ConfigFile = ConfigFile(), project: ConfigFile? = nil, projectRoot: String? = nil) {
        self.global = global
        self.project = project
        self.projectRoot = projectRoot
    }

    public var machine: MachineConfig { global.machine }

    public var throttle: ThrottleConfig {
        (global.throttle ?? ThrottleConfig()).merged(with: project?.throttle ?? ThrottleConfig())
    }

    /// Longest matching command prefix, project rules before global ones.
    public func commandRule(for words: [String]) -> CommandRule? {
        for file in [project, global].compactMap({ $0 }) {
            if let rule = Config.longestMatch(words, in: file.commands ?? [:]) { return rule }
        }
        return nil
    }

    public func scriptRule(for script: String) -> CommandRule? {
        project?.scripts?[script] ?? global.scripts?[script]
    }

    static func longestMatch(_ words: [String], in rules: [String: CommandRule]) -> CommandRule? {
        var best: (count: Int, rule: CommandRule)?
        for (key, rule) in rules {
            let prefix = key.split(separator: " ").map(String.init)
            guard !prefix.isEmpty, prefix.count <= words.count,
                  Array(words.prefix(prefix.count)) == prefix else { continue }
            if prefix.count > (best?.count ?? 0) { best = (prefix.count, rule) }
        }
        return best?.rule
    }
}

public enum ConfigLoader {
    public static let projectFileName = ".turnstilerc"

    public static func globalPath(environment: [String: String]) -> String {
        if let dir = environment["TURNSTILE_CONFIG_DIR"] { return dir + "/config.json" }
        let base = environment["XDG_CONFIG_HOME"] ?? (homeDirectory(environment) + "/.config")
        return base + "/turnstile/config.json"
    }

    /// Nearest `.turnstilerc` at or above `cwd`.
    public static func findProjectFile(from cwd: String) -> String? {
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        while true {
            let candidate = dir.appendingPathComponent(projectFileName).path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    public static func load(cwd: String, environment: [String: String]) throws -> Config {
        var config = Config()
        let globalPath = globalPath(environment: environment)
        if let data = FileManager.default.contents(atPath: globalPath) {
            do { config.global = try ConfigFile.decode(data) } catch {
                throw ConfigError(path: globalPath, underlying: error)
            }
        }
        if let projectPath = findProjectFile(from: cwd), let data = FileManager.default.contents(atPath: projectPath) {
            do { config.project = try ConfigFile.decode(data) } catch {
                throw ConfigError(path: projectPath, underlying: error)
            }
            config.projectRoot = (projectPath as NSString).deletingLastPathComponent
        }
        return config
    }
}

public struct ConfigError: Error, CustomStringConvertible {
    public let path: String
    public let underlying: Error

    public init(path: String, underlying: Error) {
        self.path = path
        self.underlying = underlying
    }

    public var description: String {
        let detail: String
        if case let DecodingError.dataCorrupted(context) = underlying {
            let syntax = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            detail = syntax.map { "invalid JSON: \($0)" } ?? (path.isEmpty ? "" : path + ": ") + context.debugDescription
        } else if case let DecodingError.typeMismatch(_, context) = underlying {
            detail = "\(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        } else {
            detail = String(describing: underlying)
        }
        return "\(path): \(detail)"
    }
}

public func homeDirectory(_ environment: [String: String]) -> String {
    environment["HOME"] ?? NSHomeDirectory()
}

extension KeyedDecodingContainer {
    func decodeSizeIfPresent(forKey key: Key) throws -> UInt64? {
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            guard let bytes = Bytes.parse(text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "bad size \"\(text)\"")
            }
            return bytes
        }
        if let megabytes = try decodeIfPresent(Double.self, forKey: key) {
            return UInt64(megabytes * Double(Bytes.mb))
        }
        return nil
    }
}
