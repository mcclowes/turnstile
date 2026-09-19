import Darwin
import Foundation
import TurnstileCore

extension Client {
    /// Connects, starting the daemon if it isn't running.
    static func connectOrStart(paths: Paths) -> Client? {
        if let client = connect(socketPath: paths.socket) { return client }
        guard !Sandbox.isActive, startDaemon(paths: paths) else { return nil }
        // Generous, because this runs when the machine is busiest.
        for _ in 0..<125 {
            usleep(40_000)
            if let client = connect(socketPath: paths.socket) { return client }
        }
        return nil
    }

    static func startDaemon(paths: Paths) -> Bool {
        guard let me = executablePath() else { return false }
        try? paths.ensure()
        rotate(paths.daemonLog, above: 1 << 20)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TURNSTILE_TOKEN")
        let pid = spawn(
            path: me,
            argv: ["turnstile", "daemon"],
            environment: environment,
            stdin: "/dev/null",
            output: paths.daemonLog,
            newSession: true
        )
        return pid != nil
    }

    /// Keeps one previous generation, so the log never grows without bound.
    static func rotate(_ path: String, above limit: UInt64) {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 ?? 0
        guard size > limit else { return }
        _ = Darwin.rename(path, path + ".1")
    }
}

func executablePath() -> String? {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
    return Resolver.canonical(String(cString: buffer))
}

/// posix_spawn with default signal handling restored in the child.
/// `closeOthers` closes every descriptor except stdio; otherwise the child inherits non-CLOEXEC fds.
/// `passing` hands the child extra descriptors, as (ours, theirs).
func spawn(path: String, argv: [String], environment: [String: String], stdin: String? = nil, output: String? = nil, stdoutFD: Int32? = nil, stderrFD: Int32? = nil, passing: [(Int32, Int32)] = [], newSession: Bool = false, closeOthers: Bool = true) -> pid_t? {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if let stdin { posix_spawn_file_actions_addopen(&actions, 0, stdin, O_RDONLY, 0) }
    if let output {
        posix_spawn_file_actions_addopen(&actions, 1, output, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
    }
    if let stdoutFD { posix_spawn_file_actions_adddup2(&actions, stdoutFD, 1) }
    if let stderrFD { posix_spawn_file_actions_adddup2(&actions, stderrFD, 2) }
    for (ours, theirs) in passing { posix_spawn_file_actions_adddup2(&actions, ours, theirs) }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for sig in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE, SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU, SIGUSR1, SIGUSR2] {
        sigaddset(&defaults, sig)
    }
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    var empty = sigset_t()
    sigemptyset(&empty)
    posix_spawnattr_setsigmask(&attributes, &empty)
    var flags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
    if closeOthers { flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT) }
    if newSession { flags |= Int16(POSIX_SPAWN_SETSID) }
    posix_spawnattr_setflags(&attributes, flags)

    // CLOEXEC_DEFAULT closes everything not named in the file actions, so keep stdio explicitly.
    for fd: Int32 in 0...2 where closeOthers && !(fd == 0 && stdin != nil) && !(fd >= 1 && output != nil) {
        let isRedirected = (fd == 1 && stdoutFD != nil) || (fd == 2 && stderrFD != nil)
        if !isRedirected { posix_spawn_file_actions_addinherit_np(&actions, fd) }
    }

    let cArgs = argv.map { strdup($0) } + [nil]
    let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        cArgs.forEach { free($0) }
        cEnv.forEach { free($0) }
    }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, path, &actions, &attributes, cArgs, cEnv)
    return result == 0 ? pid : nil
}

/// Replaces this process with the real tool.
func execReal(_ path: String, _ args: [String], environment: [String: String]? = nil) -> Never {
    let cArgs = ([path] + args).map { strdup($0) } + [nil]
    if let environment {
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(path, cArgs, cEnv)
    } else {
        execv(path, cArgs)
    }
    let error = String(cString: strerror(errno))
    FileHandle.standardError.write("turnstile: can't run \(path): \(error)\n")
    exit(126)
}

extension FileHandle {
    func write(_ text: String) {
        write(Data(text.utf8))
    }
}

func warn(_ text: String) {
    FileHandle.standardError.write("turnstile: \(text)\n")
}
