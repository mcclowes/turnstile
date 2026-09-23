import Darwin
import Foundation
import TurnstileCore

/// Child pid for the signal handlers, which can't capture context.
nonisolated(unsafe) private var forwardTarget: pid_t = 0
/// Write end of a pipe that SIGCHLD pokes, so the event loop wakes the moment the child exits.
nonisolated(unsafe) private var childExitWake: Int32 = -1
/// Set by a forwarded signal: the event loop then resumes the whole tree, since a paused job can't act on it.
nonisolated(unsafe) private var resumeRequested: sig_atomic_t = 0

enum Supervisor {
    static let taskpolicy = "/usr/sbin/taskpolicy"

    /// Entry point when invoked through a shim symlink.
    static func shim(tool: String, args: [String]) -> Never {
        let environment = ProcessInfo.processInfo.environment
        let paths = Paths(environment: environment)
        guard let real = Resolver.realBinary(tool, path: environment["PATH"] ?? "", shimsDir: paths.shims, selfPath: executablePath()) else {
            warn("\(tool): command not found (outside turnstile's shims)")
            exit(127)
        }
        if environment["TURNSTILE_DISABLE"] == "1" || paths.isDisabled || insideAdmittedJob(environment) {
            execReal(real, args)
        }
        let interactive = isatty(0) == 1 && isatty(1) == 1
        let config = loadConfig(environment: environment)
        let context = ClassifierContext(config: config, interactive: interactive)
        guard let classification = Classifier.classify(tool: tool, args: args, context: context) else {
            execReal(real, args)
        }
        gate(tool: tool, real: real, args: args, classification: classification, config: config, interactive: interactive)
    }

    /// Nested calls inside an admitted job pass straight through.
    static func insideAdmittedJob(_ environment: [String: String]) -> Bool {
        guard let token = environment["TURNSTILE_TOKEN"],
              let pid = token.split(separator: ":").last.flatMap({ pid_t($0) }) else { return false }
        return ProcessTree.isAlive(pid)
    }

    static func loadConfig(environment: [String: String]) -> Config {
        do {
            return try ConfigLoader.load(cwd: FileManager.default.currentDirectoryPath, environment: environment)
        } catch {
            warn("ignoring config, \(error)")
            return Config()
        }
    }

    static func gate(tool: String, real: String, args: [String], classification: Classification, config: Config, interactive: Bool) -> Never {
        let environment = ProcessInfo.processInfo.environment
        let paths = Paths(environment: environment)
        guard var client = Client.connectOrStart(paths: paths) else {
            if Sandbox.isActive {
                runUngated("can't reach the daemon from inside this sandbox, running \(tool) ungated (`turnstile doctor` says how to allow it)",
                           cause: "a sandbox blocked the daemon's socket", tool: tool, real: real, args: args, paths: paths)
            }
            runUngated("daemon unavailable, running \(tool) ungated (see \(paths.daemonLog))", cause: "the daemon was unavailable", tool: tool, real: real, args: args, paths: paths)
        }
        let cwd = FileManager.default.currentDirectoryPath
        let workspace = Workspace.inspect(cwd: cwd, argv: [tool] + args, environment: environment)
        let throttle = config.throttle
        let agent = Agent.isAgent(environment: environment, extraMarkers: config.machine.agentEnv ?? [], interactive: interactive)

        var request = Message(type: "request")
        request.argv = [tool] + args
        request.tool = tool
        request.key = classification.key
        request.resourceClass = classification.resourceClass
        request.memory = classification.memory
        request.cwd = cwd
        request.root = workspace.root
        request.fingerprint = workspace.fingerprint
        request.agent = agent
        request.pausable = isPausable(agent: agent, resourceClass: classification.resourceClass, configured: throttle.pause)
        request.maxMemory = throttle.maxMemory
        request.killMultiplier = throttle.killMultiplier
        request.throttleJobs = throttle.jobs
        request.nodeHeap = throttle.nodeHeap
        request.inject = throttle.inject
        request.pid = getpid()
        request.captures = isatty(1) == 0 && isatty(2) == 0
        request.interactive = interactive
        guard client.send(request) else {
            runUngated("daemon unavailable, running \(tool) ungated", cause: "the daemon was unavailable", tool: tool, real: real, args: args, paths: paths)
        }

        var lastText: String?
        var heard = false
        var reconnects = 0
        var reruns = 0
        while true {
            // A daemon answers at once, and repeats itself every 30s while a job waits; silence means it's wedged.
            switch client.read(timeout: heard ? 90 : 10) {
            case .timeout:
                runUngated("the daemon stopped answering, running \(tool) ungated (see \(paths.daemonLog))", cause: "the daemon stopped answering", tool: tool, real: real, args: args, paths: paths)
            case .closed:
                // A crashed daemon: requeue with a fresh one rather than letting every waiting job start at once.
                reconnects += 1
                if reconnects <= 3, let fresh = Client.connectOrStart(paths: paths), fresh.send(request) {
                    client = fresh
                    heard = false
                    continue
                }
                runUngated("lost the daemon while waiting, running \(tool) ungated (see \(paths.daemonLog))", cause: "lost the daemon while waiting", tool: tool, real: real, args: args, paths: paths)
            case let .message(message):
                heard = true
                switch message.type {
                case "release":
                    // No text: a nested call inside a running job, which passes straight through.
                    if let text = message.text { runUngated(text, cause: text, tool: tool, real: real, args: args, paths: paths) }
                    execReal(real, args)
                case "queued":
                    if let text = message.text {
                        warn(text)
                        lastText = text
                    }
                case "notice":
                    if let text = message.text { warn(text) }
                case "cancelled":
                    exitCancelled(message)
                case "joined":
                    follow(client: client, first: message)
                    // The run it joined ended without a result, so run it here instead.
                    reruns += 1
                    guard reruns <= 3, let fresh = Client.connectOrStart(paths: paths), fresh.send(request) else {
                        runUngated("running \(tool) ungated", cause: "the runs it joined kept ending without a result", tool: tool, real: real, args: args, paths: paths)
                    }
                    client = fresh
                    heard = false
                    lastText = nil
                case "admitted":
                    run(
                        client: client, request: request, tool: tool, real: real, args: args, job: message.job ?? 0,
                        limits: message.limits ?? JobLimits(), agent: agent, paths: paths,
                        announce: lastText != nil ? message.text : nil
                    )
                case "error":
                    let text = message.text ?? "daemon error, running \(tool) ungated"
                    runUngated(text, cause: text, tool: tool, real: real, args: args, paths: paths)
                default:
                    break
                }
            }
        }
    }

    /// Test and browser runners use wall-clock deadlines that keep advancing through SIGSTOP.
    static func isPausable(agent: Bool, resourceClass: ResourceClass, configured: Bool?) -> Bool {
        agent && (configured ?? (resourceClass == .compile))
    }

    /// Fails open, and leaves a record so `turnstile doctor` can say it happened.
    static func runUngated(_ text: String, cause: String, tool: String, real: String, args: [String], paths: Paths) -> Never {
        warn(text)
        let entry = UngatedLog.Entry(time: Date().timeIntervalSince1970, cause: cause, cwd: FileManager.default.currentDirectoryPath, command: ([tool] + args).joined(separator: " "))
        UngatedLog.append(entry, to: paths.ungatedLog)
        execReal(real, args)
    }

    // MARK: Running an admitted job

    static func run(client: Client, request: Message, tool: String, real: String, args: [String], job: Int64, limits: JobLimits, agent: Bool, paths: Paths, announce: String?) -> Never {
        if let announce { warn(announce) }
        var environment = ProcessInfo.processInfo.environment
        environment["TURNSTILE_TOKEN"] = "\(job):\(getpid())"
        let injected = Throttle.inject(tool: tool, args: args, environment: environment, limits: limits)
        environment = injected.environment

        var argv = [real] + injected.args
        var path = real
        if agent && FileManager.default.isExecutableFile(atPath: taskpolicy) {
            argv = [taskpolicy] + (request.resourceClass ?? .compile).agentPolicy + argv
            path = taskpolicy
        }

        // Capture output only when nothing is a terminal, so tools keep their colors and progress bars.
        let capture = isatty(1) == 0 && isatty(2) == 0
        var logPath: String?
        var log: Int32 = -1
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        if capture {
            let candidate = paths.log(forJob: job)
            try? FileManager.default.createDirectory(atPath: paths.logs, withIntermediateDirectories: true)
            log = open(candidate, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            if log >= 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 {
                logPath = candidate
                for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            } else {
                if log >= 0 { close(log) }
                log = -1
            }
        }

        // Like system(3): when the child shares our terminal, Ctrl-C reaches it directly and we outlive it to report.
        // Otherwise (a harness signalling this process), pass interrupts on like any other signal.
        let childOwnsTerminal = isatty(0) == 1 && tcgetpgrp(0) == getpgrp()
        var forwarded = [SIGTERM, SIGHUP]
        if childOwnsTerminal {
            signal(SIGINT, SIG_IGN)
            signal(SIGQUIT, SIG_IGN)
        } else {
            forwarded += [SIGINT, SIGQUIT]
        }
        var wake: [Int32] = [-1, -1]
        if pipe(&wake) == 0 {
            for fd in wake {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            }
            childExitWake = wake[1]
        }
        signal(SIGCHLD) { _ in
            var byte: UInt8 = 0
            if childExitWake >= 0 { _ = write(childExitWake, &byte, 1) }
        }
        for sig in forwarded {
            signal(sig) { received in
                guard forwardTarget > 0 else { return }
                kill(forwardTarget, received)
                kill(forwardTarget, SIGCONT)
                resumeRequested = 1
                var byte: UInt8 = 0
                if childExitWake >= 0 { _ = write(childExitWake, &byte, 1) }
            }
        }

        guard let child = spawn(
            path: path, argv: argv, environment: environment,
            stdoutFD: logPath != nil ? outPipe[1] : nil,
            stderrFD: logPath != nil ? errPipe[1] : nil,
            closeOthers: false
        ) else {
            warn("can't run \(real): \(String(cString: strerror(errno)))")
            var finished = Message(type: "finished")
            finished.exitCode = 126
            client.send(finished)
            exit(126)
        }
        forwardTarget = child

        var started = Message(type: "started")
        started.childPid = child
        started.log = logPath
        client.send(started)

        var streams: [(read: Int32, out: Int32)] = []
        if logPath != nil {
            close(outPipe[1])
            close(errPipe[1])
            streams = [(outPipe[0], 1), (errPipe[0], 2)]
        }

        var client = client
        var daemonOpen = true
        var released = false
        var cancelled = false
        var adoptions = 0
        var status: Int32 = 0
        var exited = false
        var drainDeadline: Date?
        var buffer = [UInt8](repeating: 0, count: 65536)

        while true {
            if !exited {
                let result = waitpid(child, &status, WNOHANG)
                if result == child || (result < 0 && errno == ECHILD) {
                    exited = true
                    drainDeadline = Date().addingTimeInterval(2)
                }
            }
            if exited && (streams.isEmpty || drainDeadline.map { $0 < Date() } == true) { break }

            var descriptors = streams.map { pollfd(fd: $0.read, events: Int16(POLLIN), revents: 0) }
            descriptors.append(pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0))
            if daemonOpen { descriptors.append(pollfd(fd: client.fd, events: Int16(POLLIN), revents: 0)) }
            _ = poll(&descriptors, nfds_t(descriptors.count), exited ? 100 : 1000)

            for (index, descriptor) in descriptors.enumerated() where descriptor.revents != 0 {
                if descriptor.fd == wake[0] {
                    while read(wake[0], &buffer, buffer.count) > 0 {}
                    if resumeRequested != 0 {
                        resumeRequested = 0
                        resume(child)
                    }
                } else if index < streams.count {
                    let count = read(descriptor.fd, &buffer, buffer.count)
                    if count > 0 {
                        writeAll(streams[index].out, buffer, count)
                        writeAll(log, buffer, count)
                    } else if count == 0 || errno != EINTR {
                        close(descriptor.fd)
                        streams[index].read = -1
                    }
                } else if client.ingest() {
                    for message in client.takePending() where ["notice", "release", "cancelled"].contains(message.type) {
                        if let text = message.text { warn(text) }
                        if message.type == "release" { released = true }
                        // The daemon signals the tree too; this covers a child it hasn't seen start yet.
                        if message.type == "cancelled" && !cancelled && !exited {
                            cancelled = true
                            kill(child, SIGTERM)
                            resume(child)
                        }
                    }
                } else {
                    daemonOpen = false
                    // A daemon that died may have paused this job, and nothing else would ever resume it.
                    resume(child)
                    if !released && !exited && adoptions < 3 {
                        adoptions += 1
                        if let fresh = adopt(request: request, child: child, log: logPath, paths: paths) {
                            client = fresh
                            daemonOpen = true
                        }
                    }
                }
            }
            streams.removeAll { $0.read < 0 }
        }
        // A background grandchild still holds the pipes. Closing them would SIGPIPE it, so a relay carries on for it.
        if !streams.isEmpty { handOff(streams, log: log) }
        if log >= 0 { close(log) }

        var finished = Message(type: "finished")
        if WIFSIGNALED(status) {
            finished.signal = WTERMSIG(status)
        } else {
            finished.exitCode = WEXITSTATUS(status)
        }
        if daemonOpen {
            client.send(finished)
            // Wait briefly for a final notice, such as a kill reason. A kill signals the tool before it tells
            // us, so a cancel can still be waiting here, and the daemon always sends it before this `ok`.
            while case let .message(message) = client.read(timeout: 0.3) {
                switch message.type {
                case "notice": if let text = message.text { warn(text) }
                case "cancelled" where !cancelled:
                    cancelled = true
                    warn(message.text ?? Turnstile.cancelledText)
                default: break
                }
                if message.type == "ok" { break }
            }
        }
        if cancelled { exit(Turnstile.cancelledExitCode) }
        exitLike(exitCode: finished.exitCode, signal: finished.signal)
    }

    static func handOff(_ streams: [(read: Int32, out: Int32)], log: Int32) {
        guard let me = executablePath() else { return }
        // Lift each source above the targets first, so one dup2 can't clobber another's source.
        func lifted(_ fd: Int32) -> Int32 { fcntl(fd, F_DUPFD_CLOEXEC, 100) }
        var passing: [(Int32, Int32)] = []
        var argv = ["turnstile", "_relay"]
        for (index, stream) in streams.enumerated() {
            passing.append((lifted(stream.read), Int32(3 + index)))
            argv.append("\(3 + index):\(stream.out)")
        }
        if log >= 0 {
            passing.append((lifted(log), 9))
            argv += ["--log", "9"]
        }
        defer { for (fd, _) in passing { close(fd) } }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TURNSTILE_TOKEN")
        _ = spawn(path: me, argv: argv, environment: environment, stdin: "/dev/null", passing: passing)
    }

    /// `turnstile _relay 3:1 4:2 [--log 9]`: copies each inherited pipe to its output until every writer has gone.
    static func relay(_ args: [String]) -> Never {
        signal(SIGPIPE, SIG_IGN)
        var log: Int32 = -1
        var streams: [(read: Int32, out: Int32)] = []
        var index = 0
        while index < args.count {
            if args[index] == "--log", index + 1 < args.count {
                log = Int32(args[index + 1]) ?? -1
                index += 2
                continue
            }
            let parts = args[index].split(separator: ":").compactMap { Int32($0) }
            if parts.count == 2 { streams.append((parts[0], parts[1])) }
            index += 1
        }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !streams.isEmpty {
            var descriptors = streams.map { pollfd(fd: $0.read, events: Int16(POLLIN), revents: 0) }
            guard poll(&descriptors, nfds_t(descriptors.count), -1) >= 0 || errno == EINTR else { break }
            for (position, descriptor) in descriptors.enumerated() where descriptor.revents != 0 {
                let count = read(descriptor.fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                // Once our reader has gone, close the pipe, so the writer sees EPIPE just as it would without us.
                if count <= 0 || !writeAll(streams[position].out, buffer, count) {
                    close(descriptor.fd)
                    streams[position].read = -1
                    continue
                }
                _ = writeAll(log, buffer, count)
            }
            streams.removeAll { $0.read < 0 }
        }
        exit(0)
    }

    static func resume(_ child: pid_t) {
        ProcessTree.signal(ProcessTree.descendants(of: child, parents: ProcessTree.parents()), SIGCONT)
    }

    /// Re-registers a running job with a fresh daemon, so it still counts against slots and memory.
    static func adopt(request: Message, child: pid_t, log: String?, paths: Paths) -> Client? {
        guard let fresh = Client.connectOrStart(paths: paths) else { return nil }
        var adopt = request
        adopt.type = "adopt"
        adopt.childPid = child
        adopt.log = log
        guard let reply = fresh.roundTrip(adopt, timeout: 2), reply.type == "ok", reply.job != nil else { return nil }
        return fresh
    }

    static func exitCancelled(_ message: Message) -> Never {
        warn(message.text ?? Turnstile.cancelledText)
        exit(Turnstile.cancelledExitCode)
    }

    static func exitLike(exitCode: Int32?, signal sig: Int32?) -> Never {
        if let sig {
            signal(sig, SIG_DFL)
            var mask = sigset_t()
            sigemptyset(&mask)
            sigaddset(&mask, sig)
            sigprocmask(SIG_UNBLOCK, &mask, nil)
            kill(getpid(), sig)
            exit(128 + sig)
        }
        exit(exitCode ?? 1)
    }

    /// False if the write failed part-way.
    @discardableResult
    static func writeAll(_ fd: Int32, _ buffer: [UInt8], _ count: Int) -> Bool {
        guard fd >= 0 else { return true }
        var offset = 0
        return buffer.withUnsafeBytes { raw in
            while offset < count {
                let written = write(fd, raw.baseAddress! + offset, count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    // MARK: Joining a run already in progress

    /// Follows another job's output and exits with its result.
    /// Returns if that run ends without a result, so the caller can run the command itself.
    static func follow(client: Client, first: Message) {
        if let text = first.text { warn(text) }
        var log: Int32 = -1
        var cancelled = false
        var buffer = [UInt8](repeating: 0, count: 65536)
        defer { if log >= 0 { close(log) } }

        func pump() {
            guard log >= 0 else { return }
            while true {
                let count = read(log, &buffer, buffer.count)
                if count <= 0 { return }
                writeAll(1, buffer, count)
            }
        }

        if let path = first.log { log = open(path, O_RDONLY | O_CLOEXEC) }
        while true {
            switch client.read(timeout: 0.2) {
            case .closed:
                pump()
                warn("lost the daemon while following another run; running it here instead")
                return
            case .timeout:
                pump()
            case let .message(message):
                pump()
                switch message.type {
                case "output":
                    if log < 0, let path = message.log { log = open(path, O_RDONLY | O_CLOEXEC) }
                case "notice":
                    if let text = message.text { warn(text) }
                case "cancelled":
                    cancelled = true
                    if let text = message.text { warn(text) }
                case "done":
                    pump()
                    if cancelled || message.cancelled == true { exit(Turnstile.cancelledExitCode) }
                    guard message.exitCode != nil || message.signal != nil else {
                        warn("\(message.text ?? "the run this joined ended without a result"); running it here instead")
                        return
                    }
                    if let text = message.text { warn(text) }
                    exitLike(exitCode: message.exitCode, signal: message.signal)
                default:
                    break
                }
            }
        }
    }
}

// The wait(2) status macros aren't imported into Swift.
private func WIFSIGNALED(_ status: Int32) -> Bool { (status & 0x7f) != 0 && (status & 0x7f) != 0x7f }
private func WTERMSIG(_ status: Int32) -> Int32 { status & 0x7f }
private func WEXITSTATUS(_ status: Int32) -> Int32 { (status >> 8) & 0xff }
