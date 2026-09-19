import Foundation

/// One kind of heavy process seen running outside every job, grouped by what it was and where.
public struct EscapeRow: Codable, Equatable, Sendable {
    public var label: String
    public var via: String
    public var cwd: String
    public var count: Int
    public var lastSeen: Double

    public init(label: String, via: String, cwd: String, count: Int, lastSeen: Double) {
        self.label = label
        self.via = via
        self.cwd = cwd
        self.count = count
        self.lastSeen = lastSeen
    }
}

/// Recognises builds and test runs that never went through a shim: absolute paths, `node_modules/.bin`,
/// Xcode's own build service, and tools turnstile doesn't shim. The daemon watches for them while it's awake.
public enum Escapes {
    /// Processes heavy enough to matter on their own.
    static let heavy: Set<String> = [
        "swift-frontend", "swift-driver", "swift-build", "swiftc", "swift-plugin-server",
        "rustc", "xcodebuild", "ninja", "cmake", "bazel", "javac", "pytest", "cc1", "cc1plus",
    ]

    /// Runtimes that only count once you look at what they're running.
    static let nodeScripts: Set<String> = ["vitest", "jest", "tsc", "next", "webpack", "playwright", "esbuild", "rollup", "turbo"]

    /// Whether a process name is worth reading arguments for. Cheap, so a scan can ask it of every process.
    public static func isCandidate(_ name: String) -> Bool { tools.contains(name) }

    /// What to call this process in a report, or nil to ignore it. `args` excludes argv[0].
    public static func label(executable: String, args: [String]) -> String? {
        let name = (executable as NSString).lastPathComponent
        if heavy.contains(name) { return name }
        switch name {
        case "clang", "clang++", "gcc", "g++":
            // The driver forks one of these per file; only the compile itself is worth counting.
            return args.contains("-cc1") ? "clang" : nil
        case "node", "bun", "deno":
            guard let script = args.first(where: { !$0.hasPrefix("-") }) else { return nil }
            guard let tool = nodeTool(script) else { return nil }
            return "\(name) \(tool)"
        case "java":
            return args.contains(where: { $0.hasPrefix("org.gradle") }) ? "gradle" : nil
        case "python", "python3":
            guard let index = args.firstIndex(of: "-m"), index + 1 < args.count else { return nil }
            return args[index + 1] == "pytest" ? "pytest" : nil
        default:
            return nil
        }
    }

    /// The tool a node script path runs, from `node_modules/.bin/vitest` or `node_modules/vitest/vitest.mjs`.
    static func nodeTool(_ script: String) -> String? {
        let parts = script.split(separator: "/").map(String.init)
        guard parts.contains("node_modules") else { return nil }
        let base = (script as NSString).lastPathComponent
        let stem = base.split(separator: ".").first.map(String.init) ?? base
        if nodeScripts.contains(stem) { return stem }
        // `node_modules/jest-cli/bin/jest.js`: fall back to the package the script belongs to.
        guard let index = parts.lastIndex(of: "node_modules"), index + 1 < parts.count else { return nil }
        let package = parts[index + 1].split(separator: "-").first.map(String.init) ?? parts[index + 1]
        return nodeScripts.contains(package) && !base.hasPrefix("tsserver") ? package : nil
    }

    /// Friendlier names for the processes that spawn build tools without a shell.
    static let harnesses = ["XCBBuildService": "Xcode", "SWBBuildService": "Xcode", "Xcode": "Xcode", "sourcekit-lsp": "sourcekit-lsp"]

    /// Names a build tool answers to, so the chain can be walked past them to whoever really started the work.
    static let tools: Set<String> = heavy.union(["node", "bun", "deno", "java", "python", "python3", "clang", "clang++", "gcc", "g++"])

    /// Who started it: a known harness anywhere up the chain, else the nearest ancestor that isn't a build tool itself.
    public static func via(chain: [String]) -> String {
        if let harness = chain.compactMap({ harnesses[$0] }).first { return harness }
        return chain.first { !tools.contains($0) } ?? chain.first ?? "an unknown process"
    }

    /// One line for `turnstile doctor`, busiest first.
    public static func report(_ rows: [EscapeRow], home: String) -> String? {
        guard !rows.isEmpty else { return nil }
        return rows.map { row in
            let cwd = row.cwd.hasPrefix(home + "/") ? "~" + row.cwd.dropFirst(home.count) : row.cwd
            return "\(row.count) × \(row.label) under \(row.via) in \(cwd)"
        }.joined(separator: ", ")
    }
}
