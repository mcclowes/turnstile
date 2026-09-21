import Foundation

public enum Turnstile {
    public static let version = "0.5.0"
    /// Exit code for a run someone killed on purpose, so agents know not to retry it.
    public static let cancelledExitCode: Int32 = 125
    public static let cancelledText = "cancelled by you, don't retry"
}

public struct Paths: Sendable {
    public let home: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        home = environment["TURNSTILE_HOME"] ?? (homeDirectory(environment) + "/.turnstile")
    }

    public init(home: String) {
        self.home = home
    }

    public var shims: String { home + "/shims" }
    public var bin: String { home + "/bin" }
    /// Unix socket paths max out at 104 bytes; a deep home falls back to a short per-home path in /tmp.
    public var socket: String {
        let preferred = home + "/turnstiled.sock"
        if preferred.utf8.count < 100 { return preferred }
        let hash = home.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        return "/tmp/turnstile-\(getuid())-\(String(hash, radix: 36)).sock"
    }
    public var database: String { home + "/state.sqlite" }
    public var logs: String { home + "/logs" }
    public var daemonLog: String { home + "/daemon.log" }
    public var ungatedLog: String { home + "/ungated.log" }
    public var lock: String { home + "/daemon.lock" }
    /// While this file exists every shim passes straight through (`turnstile disable`, or the menu bar toggle).
    public var disabledFlag: String { home + "/disabled" }

    public var isDisabled: Bool { FileManager.default.fileExists(atPath: disabledFlag) }

    /// When gating was turned off, or nil while it's on.
    public var disabledSince: Date? {
        (try? FileManager.default.attributesOfItem(atPath: disabledFlag))?[.modificationDate] as? Date
    }

    public func setDisabled(_ disabled: Bool) throws {
        try setFlag(disabledFlag, disabled)
    }

    /// While this file exists the daemon admits nothing new; running jobs carry on.
    public var queuePausedFlag: String { home + "/queue-paused" }

    public var isQueuePaused: Bool { FileManager.default.fileExists(atPath: queuePausedFlag) }

    public func setQueuePaused(_ paused: Bool) throws {
        try setFlag(queuePausedFlag, paused)
    }

    /// Leaves an existing flag untouched, so its modification date says when it was first set.
    private func setFlag(_ path: String, _ on: Bool) throws {
        let exists = FileManager.default.fileExists(atPath: path)
        if !on {
            if exists { try FileManager.default.removeItem(atPath: path) }
            return
        }
        guard !exists else { return }
        try ensure()
        guard FileManager.default.createFile(atPath: path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
    }

    public func ensure() throws {
        for dir in [home, shims, logs] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }
}

public enum Agent {
    /// Variables that agent harnesses set in the shells they run.
    public static let defaultMarkers = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CODEX_SANDBOX", "CODEX_MANAGED_BY_NPM", "CODEX_THREAD_ID",
        "GEMINI_CLI", "CURSOR_AGENT", "AIDER_MODEL", "OPENCODE", "AMP_THREAD_ID",
    ]

    /// `TURNSTILE_AGENT=1/0` forces the answer. Otherwise agent markers, or no terminal at all, mean an agent.
    public static func isAgent(environment: [String: String], extraMarkers: [String] = [], interactive: Bool) -> Bool {
        if let forced = environment["TURNSTILE_AGENT"] { return forced != "0" && forced != "" }
        if (defaultMarkers + extraMarkers).contains(where: { environment[$0] != nil }) { return true }
        return !interactive
    }
}

public enum Resolver {
    /// First executable named `tool` on PATH that isn't a turnstile shim.
    public static func realBinary(_ tool: String, path: String, shimsDir: String, selfPath: String?) -> String? {
        let shims = canonical(shimsDir)
        let me = selfPath.map(canonical)
        for dir in path.split(separator: ":").map(String.init) where !dir.isEmpty {
            if canonical(dir) == shims { continue }
            let candidate = (dir as NSString).appendingPathComponent(tool)
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue { continue }
            if let me, canonical(candidate) == me { continue }
            return candidate
        }
        return nil
    }

    /// For a Homebrew install, the prefix's `bin/turnstile` link, which `brew upgrade` repoints; the Cellar path it resolves to doesn't survive an upgrade.
    public static func homebrewLink(for executable: String) -> String? {
        guard let range = executable.range(of: "/Cellar/turnstile/") else { return nil }
        return executable[..<range.lowerBound] + "/bin/turnstile"
    }

    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
