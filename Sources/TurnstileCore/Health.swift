import Foundation

/// What the menu bar app can tell about the install without a shell or the daemon.
/// `turnstile doctor` goes deeper, but it reads a login shell's PATH and starts the daemon, and the app can do neither.
public enum Health {
    public static let brokenSymbol = "exclamationmark.octagon"

    public struct Evidence: Equatable, Sendable {
        public var cliInstalled: Bool
        /// At least one shim links to the installed CLI.
        public var shimsInstalled: Bool
        /// The global config file, when it doesn't decode and is ignored.
        public var configError: String?
        /// When a shim last registered a command with the daemon. History older than 30 days is pruned.
        public var lastGated: Double?

        public init(cliInstalled: Bool, shimsInstalled: Bool, configError: String?, lastGated: Double?) {
            self.cliInstalled = cliInstalled
            self.shimsInstalled = shimsInstalled
            self.configError = configError
            self.lastGated = lastGated
        }
    }

    public struct Finding: Equatable, Sendable {
        /// `.danger` when nothing is gated, `.warning` when something is probably off.
        public var tone: MenuBarState.Tone
        public var text: String
        public var fix: String?
        /// `fix` is a shell command the app can run in Terminal, not just advice to read.
        public var runnable: Bool

        public init(tone: MenuBarState.Tone, text: String, fix: String?, runnable: Bool = true) {
            self.tone = tone
            self.text = text
            self.fix = fix
            self.runnable = runnable && fix != nil
        }
    }

    /// A `.command` file that Terminal runs in a login shell, so Homebrew is on PATH.
    public static func terminalScript(for command: String) -> String {
        """
        #!/bin/zsh -l
        clear
        print -r -- \(shellQuoted("$ " + command))
        \(command)
        print "\\nDone. You can close this window."
        rm -f -- "$0"

        """
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Filesystem checks and one read-only query. Cheap, and never creates files or starts the daemon.
    public static func gather(paths: Paths, environment: [String: String] = ProcessInfo.processInfo.environment) -> Evidence {
        let cli = paths.bin + "/turnstile"
        let target = Resolver.canonical(cli)
        let shims = (try? FileManager.default.contentsOfDirectory(atPath: paths.shims)) ?? []
        let configPath = ConfigLoader.globalPath(environment: environment)
        let configBroken = FileManager.default.contents(atPath: configPath).map { (try? ConfigFile.decode($0)) == nil } ?? false
        return Evidence(
            cliInstalled: FileManager.default.isExecutableFile(atPath: cli),
            shimsInstalled: shims.contains { Resolver.canonical(paths.shims + "/" + $0) == target },
            configError: configBroken ? configPath : nil,
            lastGated: FileManager.default.fileExists(atPath: paths.database) ? Store.lastQueued(path: paths.database) : nil
        )
    }

    /// Most serious first. Empty when all is well. The disabled flag isn't here: the menu's toggle and icon own it.
    public static func findings(_ evidence: Evidence, snapshot: StatusSnapshot?, appVersion: String = Turnstile.version) -> [Finding] {
        guard evidence.cliInstalled else {
            return [Finding(
                tone: .danger, text: "Nothing is gated: the turnstile command isn't set up",
                fix: "brew install mcclowes/turnstile/turnstile && turnstile init"
            )]
        }
        var findings: [Finding] = []
        if !evidence.shimsInstalled {
            findings.append(Finding(tone: .danger, text: "Nothing is gated: the shims are missing", fix: "turnstile shims"))
        }
        if evidence.lastGated == nil && evidence.shimsInstalled {
            findings.append(Finding(
                tone: .warning, text: "No command has gone through the shims yet",
                fix: "open a new shell so the shims are on PATH, then run: turnstile doctor",
                runnable: false
            ))
        }
        if let path = evidence.configError {
            findings.append(Finding(tone: .warning, text: "\(path) is invalid, so it's ignored", fix: "turnstile config check"))
        }
        if let snapshot, snapshot.version != appVersion {
            let daemon = snapshot.version ?? "0.1"
            let behind = daemon.compare(appVersion, options: .numeric) == .orderedAscending
            findings.append(Finding(
                tone: .warning, text: "The daemon is turnstile \(daemon) but this app is \(appVersion)",
                fix: behind ? "brew upgrade turnstile && turnstile restart" : "brew upgrade turnstile-app"
            ))
        }
        return findings
    }
}

extension MenuBarState {
    /// The status icon, overridden while the install is broken. Memory trouble and gating off still beat a mere warning.
    public static func indicator(_ snapshot: StatusSnapshot?, health: [Health.Finding], disabled: Bool = false) -> Indicator {
        let base = indicator(snapshot, disabled: disabled)
        if health.contains(where: { $0.tone == .danger }) {
            return Indicator(symbol: Health.brokenSymbol, count: base.count, tone: .danger)
        }
        if health.contains(where: { $0.tone == .warning }) && base.tone != .danger {
            return Indicator(symbol: Health.brokenSymbol, count: base.count, tone: .warning)
        }
        return base
    }
}
