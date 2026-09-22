import Foundation

/// Asks other shells, not just the one `turnstile doctor` runs in, where their build tools come from.
/// An agent harness starts its own shell, and a session older than `turnstile init` keeps the PATH it started with.
public enum ShellCheck {
    public struct Probe: Sendable {
        public var name: String
        public var binary: String
        public var arguments: [String]

        public init(name: String, binary: String, arguments: [String]) {
            self.name = name
            self.binary = binary
            self.arguments = arguments
        }
    }

    /// Login shells read the startup files turnstile edits; the others only inherit PATH, which is what agents do.
    public static let probes = [
        Probe(name: "zsh -c", binary: "/bin/zsh", arguments: ["-c"]),
        Probe(name: "zsh -lc", binary: "/bin/zsh", arguments: ["-lc"]),
        Probe(name: "zsh -ic", binary: "/bin/zsh", arguments: ["-ic"]),
        Probe(name: "bash -lc", binary: "/bin/bash", arguments: ["-lc"]),
    ]

    public struct Verdict: Equatable, Sendable {
        public var shimmed: [String] = []
        /// Tools found somewhere else first, as "name (path)".
        public var shadowed: [String] = []
        public var missing: [String] = []
    }

    public enum Location: Equatable, Sendable {
        /// The shim wins; `real` is what it forwards to, nil when the tool isn't installed.
        case shimmed(real: String?)
        case elsewhere(String)
        case missing
    }

    /// Tool names can't contain "/", so this key can't collide with one.
    private static let pathKey = "/PATH"

    public static func script(tools: [String]) -> String {
        let names = tools.map { "'" + $0.replacingOccurrences(of: "'", with: "") + "'" }.joined(separator: " ")
        return "printf '%s\\t%s\\n' '\(pathKey)' \"$PATH\"; "
            + "for tool in \(names); do printf '%s\\t%s\\n' \"$tool\" \"$(command -v \"$tool\" 2>/dev/null)\"; done"
    }

    public static func locations(output: String, shimsDir: String) -> [String: Location] {
        let shims = Resolver.canonical(shimsDir)
        let answers = self.answers(output)
        let path = answers.first { $0.0 == pathKey }?.1 ?? ""
        var found: [String: Location] = [:]
        for (tool, location) in answers where tool != pathKey {
            if location.isEmpty {
                found[tool] = .missing
            } else if Resolver.canonical((location as NSString).deletingLastPathComponent) == shims {
                found[tool] = .shimmed(real: Resolver.realBinary(tool, path: path, shimsDir: shimsDir, selfPath: nil))
            } else {
                found[tool] = .elsewhere(location)
            }
        }
        return found
    }

    public static func verdict(output: String, shimsDir: String) -> Verdict {
        var verdict = Verdict()
        let found = locations(output: output, shimsDir: shimsDir)
        for (tool, _) in answers(output) {
            switch found[tool] {
            case .missing: verdict.missing.append(tool)
            case .shimmed: verdict.shimmed.append(tool)
            case .elsewhere(let path): verdict.shadowed.append("\(tool) (\(path))")
            case nil: continue
            }
        }
        return verdict
    }

    /// Startup files can print to stdout, so only tab-separated pairs count.
    private static func answers(_ output: String) -> [(String, String)] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return fields.count == 2 ? (fields[0], fields[1]) : nil
        }
    }

    /// A bare environment, as a harness that starts its own shell has; startup files build PATH from there.
    public static func bareEnvironment(from environment: [String: String]) -> [String: String] {
        var bare = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": homeDirectory(environment)]
        for key in ["USER", "LOGNAME", "TMPDIR", "LANG", "TERM", "SHELL", "TURNSTILE_HOME"] {
            if let value = environment[key] { bare[key] = value }
        }
        return bare
    }

    /// Runs the probe with a bare environment, as a harness that starts its own shell would.
    public static func ask(_ probe: Probe, tools: [String], environment: [String: String], timeout: Double = 15) -> String? {
        guard FileManager.default.isExecutableFile(atPath: probe.binary) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: probe.binary)
        process.arguments = probe.arguments + [script(tools: tools)]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The PATH an agent harness's shell snapshot replays, if it sets one.
    public static func snapshotPath(_ contents: String) -> String? {
        var found: String?
        for line in contents.split(separator: "\n") where line.hasPrefix("export PATH=") {
            let value = line.dropFirst("export PATH=".count).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if !value.isEmpty { found = value }
        }
        return found
    }

    /// The newest shell snapshot an agent harness left behind, if any.
    public static func newestSnapshot(in directory: String) -> String? {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(atPath: directory)) ?? []
        let dated = files.compactMap { file -> (String, Date)? in
            let path = directory + "/" + file
            guard let modified = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
            return (path, modified)
        }
        return dated.max { $0.1 < $1.1 }?.0
    }
}
