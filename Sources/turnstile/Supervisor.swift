import Darwin
import Foundation
import TurnstileCore

/// Child pid for the signal handlers, which can't capture context.
nonisolated(unsafe) private var forwardTarget: pid_t = 0
/// Write end of a pipe that SIGCHLD pokes, so the event loop wakes the moment the child exits.
nonisolated(unsafe) private var childExitWake: Int32 = -1

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
            warn("daemon unavailable, running \(tool) ungated (see \(paths.daemonLog))")
            execReal(real, args)
        }
        let cwd = FileManager.default.currentDirectoryPath
        let workspace = Workspace.inspect(cwd: cwd, argv: [tool] + args)
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
        request.pausable = agent && (throttle.pause ?? true)
        request.maxMemory = throttle.maxMemory
        request.killMultiplier = throttle.killMultiplier
        request.throttleJobs = throttle.jobs
        request.nodeHeap = throttle.nodeHeap
        request.inject = throttle.inject
        request.pid = getpid()
        guard client.send(request) else {
            warn("daemon unavailable, running \(tool) ungated")
            execReal(real, args)
        }

        var lastText: String?
        var heard = false
        var reconnects = 0
        while true {
            // A daemon answers at once, and repeats itself every 30s while a job waits; silence means it's wedged.
            switch client.read(timeout: heard ? 90 : 10) {
            case .timeout:
                warn("the daemon stopped answering, running \(tool) ungated (see \(paths.daemonLog))")
                execReal(real, args)
            case .closed:
                // A crashed daemon: requeue with a fresh one rather than letting every waiting job start at once.
                reconnects += 1
                if reconnects <= 3, let fresh = Client.connectOrStart(paths: paths), fresh.send(request) {
                    client = fresh
                    heard = false
                    continue
                }
                warn("lost the daemon while waiting, running \(tool) ungated (see \(paths.daemonLog))")
                execReal(real, args)
            case let .message(message):
                heard = true
                switch message.type {
                case "release":
                    warn(message.text ?? "daemon stopped; running \(tool) ungated")
                    execReal(real, args)
                case "queued":
                    if let text = message.text {
                        warn(text)
                        lastText = text
                    }
                case "notice":
                    if let text = message.text { warn(text) }
                case "joined":
                    follow(client: client, first: message)
                case "admitted":
                    run(
                        client: client, tool: tool, real: real, args: args, job: message.job ?? 0,
                        limits: message.limits ?? JobLimits(), agent: agent, paths: paths,
                        announce: lastText != nil ? message.text : nil
                    )
                case "error":
                    warn(message.text ?? "daemon error, running \(tool) ungated")
                    execReal(real, args)
                default:
                    break
                }
            }
        }
    }

    // MARK: Running an admitted job

    static func run(client: Client, tool: String, real: String, args: [String], job: Int64, limits: JobLimits, agent: Bool, paths: Paths, announce: String?) -> Never {
        if let announce { warn(announce) }
        var environment = ProcessInfo.processInfo.environment
        environment["TURNSTILE_TOKEN"] = "\(job):\(getpid())"
        let injected = Throttle.inject(tool: tool, args: args, environment: environment, limits: limits)
        environment = injected.environment

        var argv = [real] + injected.args
        var path = real
        if agent && FileManager.default.isExecutableFile(atPath: taskpolicy) {
            argv = [taskpolicy, "-b"] + argv
            path = taskpolicy
        }

        // Capture output only when nothing is a terminal, so tools keep their colors and progress bars.
        let capture = isatty(1) == 0 && isatty(2) == 0
        var logPath: String?
        var log: Int32 = -1
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        if capture {
            let candidate = "\(paths.logs)/\(job).log"
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

        // Like system(3): the terminal's Ctrl-C reaches the child directly, and we outlive it to report.
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
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
        for sig in [SIGTERM, SIGHUP] {
            signal(sig) { received in if forwardTarget > 0 { kill(forwardTarget, received) } }
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

        var daemonOpen = true
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
                    for message in client.takePending() where message.type == "notice" {
                        if let text = message.text { warn(text) }
                    }
                } else {
                    daemonOpen = false
                }
            }
            streams.removeAll { $0.read < 0 }
        }
        if log >= 0 { close(log) }

        var finished = Message(type: "finished")
        if WIFSIGNALED(status) {
            finished.signal = WTERMSIG(status)
        } else {
            finished.exitCode = WEXITSTATUS(status)
        }
        if daemonOpen {
            client.send(finished)
            // Wait briefly for a final notice, such as a kill reason.
            while case let .message(message) = client.read(timeout: 0.3) {
                if message.type == "notice", let text = message.text { warn(text) }
                if message.type == "ok" { break }
            }
        }
        exitLike(exitCode: finished.exitCode, signal: finished.signal)
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

    static func writeAll(_ fd: Int32, _ buffer: [UInt8], _ count: Int) {
        guard fd >= 0 else { return }
        var offset = 0
        buffer.withUnsafeBytes { raw in
            while offset < count {
                let written = write(fd, raw.baseAddress! + offset, count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    // MARK: Joining a run already in progress

    /// Follows another job's output and exits with its result.
    static func follow(client: Client, first: Message) -> Never {
        if let text = first.text { warn(text) }
        var log: Int32 = -1
        var buffer = [UInt8](repeating: 0, count: 65536)

        func pump() {
            guard log >= 0 else { return }
            while true {
                let count = read(log, &buffer, buffer.count)
                if count <= 0 { return }
                writeAll(1, buffer, count)
            }
        }
        func handle(_ message: Message) -> Never? {
            switch message.type {
            case "output":
                if log < 0, let path = message.log { log = open(path, O_RDONLY | O_CLOEXEC) }
            case "notice":
                if let text = message.text { warn(text) }
            case "done":
                pump()
                if let text = message.text { warn(text) }
                if message.exitCode == nil && message.signal == nil { exit(75) }
                exitLike(exitCode: message.exitCode, signal: message.signal)
            default:
                break
            }
            return nil
        }

        if let path = first.log { log = open(path, O_RDONLY | O_CLOEXEC) }
        while true {
            switch client.read(timeout: 0.2) {
            case .closed:
                pump()
                warn("lost the daemon; the run this joined may still be going")
                exit(75)
            case .timeout:
                pump()
            case let .message(message):
                pump()
                _ = handle(message)
            }
        }
    }
}

// The wait(2) status macros aren't imported into Swift.
private func WIFSIGNALED(_ status: Int32) -> Bool { (status & 0x7f) != 0 && (status & 0x7f) != 0x7f }
private func WTERMSIG(_ status: Int32) -> Int32 { status & 0x7f }
private func WEXITSTATUS(_ status: Int32) -> Int32 { (status >> 8) & 0xff }
