import Darwin
import Foundation
import TurnstileCore

/// The machine-wide scheduler. One per user, found through a Unix socket in the turnstile home.
/// Everything runs on the main queue, so state needs no locking.
final class Daemon {
    final class Connection {
        let fd: Int32
        var source: DispatchSourceRead?
        var lines = LineBuffer()
        /// Job this client owns, or follows as a joiner.
        var job: Int64?
        var joined = false

        init(fd: Int32) { self.fd = fd }

        func send(_ message: Message) {
            let data = message.encoded()
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    offset += written
                }
            }
        }
    }

    enum State: String { case queued, running, orphaned }

    final class Job {
        let id: Int64
        let resourceClass: ResourceClass
        let key: String
        let root: String
        let cwd: String
        let argv: [String]
        let agent: Bool
        let clientPid: Int32
        let fingerprint: String?
        let estimate: UInt64
        let usualPeak: UInt64?
        let throttle: ThrottleConfig
        let pausable: Bool
        let queuedAt: Double
        var state = State.queued
        var owner: Connection?
        var joiners: [Connection] = []
        var bumpedAt: Double?
        var startedAt: Double?
        var childPid: Int32?
        var log: String?
        var footprint: UInt64 = 0
        var peak: UInt64 = 0
        var ceiling: UInt64 = .max
        var paused = false
        var killReason: String?
        var killDeadline: Double?
        var lastWait: String?
        var lastWaitSentAt: Double = 0
        var tree: [pid_t] = []

        init(id: Int64, request: Message, estimate: UInt64, usualPeak: UInt64?, now: Double) {
            self.id = id
            resourceClass = request.resourceClass ?? .compile
            key = request.key ?? request.tool ?? "?"
            root = request.root ?? request.cwd ?? "/"
            cwd = request.cwd ?? root
            argv = request.argv ?? []
            agent = request.agent ?? true
            clientPid = request.pid ?? 0
            fingerprint = request.fingerprint
            self.estimate = estimate
            self.usualPeak = usualPeak
            throttle = ThrottleConfig(
                inject: request.inject, jobs: request.throttleJobs, nodeHeap: request.nodeHeap,
                maxMemory: request.maxMemory, killMultiplier: request.killMultiplier
            )
            pausable = request.pausable ?? agent
            queuedAt = now
        }

        var project: String { projectName(root) }
        var label: String { "\(project) \(key), ~\(Bytes.format(max(estimate, peak)))" }
        /// Same command in the same place, whatever the tree's contents.
        var identity: String { ([root, cwd] + argv).joined(separator: "\u{0}") }
        var connections: [Connection] { (owner.map { [$0] } ?? []) + joiners }
    }

    let paths: Paths
    let store: Store
    var config = ConfigFile()
    var configModified: Date?
    var jobs: [Int64: Job] = [:]
    var connections: [ObjectIdentifier: Connection] = [:]
    var listener: DispatchSourceRead?
    var timer: DispatchSourceTimer?
    var memoryLevel = 100
    var ticks = 0
    var lastPressureAction: Double = 0
    var idleSince = Date().timeIntervalSince1970
    let idleExit: Double
    let physical = SystemMemory.physical
    let cpuCount = SystemMemory.cpuCount

    init(paths: Paths, idleExit: Double) throws {
        self.paths = paths
        self.idleExit = idleExit
        try paths.ensure()
        store = try Store(path: paths.database)
    }

    static func now() -> Double { Date().timeIntervalSince1970 }

    // MARK: Lifecycle

    func run() -> Never {
        let lock = open(paths.lock, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            log("another daemon holds \(paths.lock); exiting")
            exit(0)
        }
        ftruncate(lock, 0)
        let pidText = "\(getpid())\n"
        _ = pidText.withCString { write(lock, $0, strlen($0)) }

        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.shutdown(reason: "signal \(sig)") }
            source.resume()
            retained.append(source)
        }

        store.abandonOpenJobs(now: Daemon.now())
        store.prune(olderThan: Daemon.now() - 30 * 86400)
        cleanLogs()
        reloadConfig()
        memoryLevel = SystemMemory.level()
        listen()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        log("started, pid \(getpid()), memory \(memoryLevel)% free")
        dispatchMain()
    }

    private var retained: [DispatchSourceSignal] = []

    func shutdown(reason: String) -> Never {
        log("stopping: \(reason)")
        for job in jobs.values where job.paused { ProcessTree.signal(job.tree, SIGCONT) }
        for job in jobs.values {
            for connection in job.connections { connection.send(.notice("daemon stopped; \(job.state == .queued ? "running ungated" : "continuing untracked")")) }
        }
        unlink(paths.socket)
        exit(0)
    }

    func log(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write("\(stamp) \(text)\n")
    }

    func listen() {
        unlink(paths.socket)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(paths.socket.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes.prefix(buffer.count - 1))
            buffer[min(bytes.count, buffer.count - 1)] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard fd >= 0, bound == 0, Darwin.listen(fd, 64) == 0 else {
            log("can't listen on \(paths.socket): \(String(cString: strerror(errno)))")
            exit(1)
        }
        chmod(paths.socket, 0o600)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept(on: fd) }
        source.resume()
        listener = source
    }

    func accept(on listenFD: Int32) {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connection = Connection(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.read(connection)
        }
        source.setCancelHandler { close(fd) }
        connection.source = source
        connections[ObjectIdentifier(connection)] = connection
        source.resume()
    }

    func read(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(connection.fd, &chunk, chunk.count)
        if count < 0 && errno == EINTR { return }
        guard count > 0 else {
            disconnected(connection)
            return
        }
        for line in connection.lines.append(Data(chunk[0..<count])) {
            if let message = Message.decode(line) { handle(message, from: connection) }
        }
    }

    // MARK: Messages

    func handle(_ message: Message, from connection: Connection) {
        switch message.type {
        case "request": request(message, from: connection)
        case "started": started(message, from: connection)
        case "finished": finished(message, from: connection)
        case "status":
            var reply = Message(type: "status")
            reply.status = snapshot()
            connection.send(reply)
        case "bump": connection.send(bump(message.target ?? ""))
        case "stop":
            connection.send(Message(type: "ok"))
            shutdown(reason: "requested")
        default:
            connection.send(.error("unknown message \(message.type)"))
        }
    }

    func request(_ message: Message, from connection: Connection) {
        let now = Daemon.now()
        let key = message.key ?? message.tool ?? "?"
        let root = message.root ?? message.cwd ?? "/"
        let usual = store.usualPeak(key: key, root: root)
        let estimate = message.memory ?? usual ?? (message.resourceClass ?? .compile).defaultEstimate
        let id = store.insertJob(
            state: "queued", resourceClass: message.resourceClass ?? .compile, key: key, root: root,
            cwd: message.cwd ?? root, argv: message.argv ?? [], agent: message.agent ?? true,
            clientPid: message.pid ?? 0, estimate: estimate, now: now
        )
        let job = Job(id: id, request: message, estimate: estimate, usualPeak: usual, now: now)
        connection.job = id

        // The same command on the same tree contents joins the run in progress.
        if let fingerprint = job.fingerprint,
           let twin = jobs.values.first(where: { $0.fingerprint == fingerprint && $0.root == job.root && $0.killReason == nil }) {
            attach(connection, to: twin, text: "joining an identical \(twin.key) already \(twin.state == .queued ? "queued" : "running") in \(twin.project) (#\(twin.id))")
            store.markJoined(id, to: twin.id, outcome: "joined", exitCode: nil, now: now)
            connection.job = twin.id
            return
        }

        jobs[id] = job
        job.owner = connection

        // A newer request from the same worktree replaces its queued one; the older caller gets this run's result.
        for stale in jobs.values where stale.id != id && stale.state == .queued && stale.identity == job.identity {
            jobs.removeValue(forKey: stale.id)
            for follower in stale.connections {
                attach(follower, to: job, text: "superseded by a newer \(job.key) from this worktree (#\(job.id)); reporting its result")
            }
            store.markJoined(stale.id, to: id, outcome: "superseded", exitCode: nil, now: now)
        }

        idleSince = now
        schedule()
    }

    func attach(_ connection: Connection, to job: Job, text: String) {
        connection.joined = true
        connection.job = job.id
        job.joiners.append(connection)
        var reply = Message(type: "joined")
        reply.job = job.id
        reply.text = text
        reply.log = job.log
        connection.send(reply)
    }

    func started(_ message: Message, from connection: Connection) {
        guard let id = connection.job, let job = jobs[id], job.owner === connection else { return }
        job.childPid = message.childPid
        job.log = message.log
        store.markStarted(id, childPid: message.childPid, now: Daemon.now())
        var output = Message(type: "output")
        output.log = job.log
        for joiner in job.joiners where job.log != nil { joiner.send(output) }
        sample(job, parents: ProcessTree.parents())
    }

    func finished(_ message: Message, from connection: Connection) {
        guard let id = connection.job, let job = jobs[id], job.owner === connection else { return }
        complete(job, exitCode: message.exitCode, signal: message.signal)
        connection.send(Message(type: "ok"))
    }

    func complete(_ job: Job, exitCode: Int32?, signal: Int32?, lost: Bool = false) {
        guard jobs.removeValue(forKey: job.id) != nil else { return }
        let now = Daemon.now()
        let outcome: String
        if job.killReason != nil { outcome = "killed" }
        else if lost { outcome = "lost" }
        else if exitCode == 0 { outcome = "ok" }
        else if signal != nil { outcome = "signaled" }
        else { outcome = "failed" }
        if job.paused { ProcessTree.signal(job.tree, SIGCONT) }
        store.markFinished(job.id, outcome: outcome, exitCode: exitCode, signal: signal, peak: job.peak > 0 ? job.peak : nil, now: now)
        log("#\(job.id) \(job.project) \(job.key): \(outcome), peak \(Bytes.format(job.peak))")

        var done = Message(type: "done")
        done.job = job.id
        done.exitCode = exitCode
        done.signal = signal
        if lost { done.text = "the run this joined ended without a result; run it again" }
        else if let reason = job.killReason { done.text = reason }
        for joiner in job.joiners { joiner.send(done) }
        job.joiners.removeAll()
        schedule()
    }

    func disconnected(_ connection: Connection) {
        connection.source?.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        guard let id = connection.job, let job = jobs[id] else { return }
        if connection.joined {
            job.joiners.removeAll { $0 === connection }
            return
        }
        guard job.owner === connection else { return }
        job.owner = nil
        switch job.state {
        case .queued:
            jobs.removeValue(forKey: id)
            store.markFinished(id, outcome: "cancelled", exitCode: nil, signal: nil, peak: nil, now: Daemon.now())
            var done = Message(type: "done")
            done.text = "the run this joined was cancelled; run it again"
            for joiner in job.joiners { joiner.send(done) }
            schedule()
        case .running, .orphaned:
            // The client died. Keep the slot until the job's processes are gone too.
            if let child = job.childPid, ProcessTree.isAlive(child) {
                job.state = .orphaned
                log("#\(id) client exited; tracking pid \(child) until it exits")
            } else {
                complete(job, exitCode: nil, signal: nil, lost: true)
            }
        }
    }

    // MARK: Scheduling

    var policy: SchedulerPolicy {
        var limits: [ResourceClass: Int] = [:]
        for cls in ResourceClass.allCases {
            limits[cls] = config.machine.concurrencyLimit(for: cls, cpuCount: cpuCount)
        }
        return SchedulerPolicy(classLimits: limits, reserve: config.machine.reserveBytes)
    }

    func schedule() {
        let queued = jobs.values.filter { $0.state == .queued }
        guard !queued.isEmpty else { return }
        let running = jobs.values.filter { $0.state != .queued }
        let decision = Scheduler.decide(
            queue: queued.map { QueuedJob(id: $0.id, resourceClass: $0.resourceClass, estimate: $0.estimate, agent: $0.agent, bumpedAt: $0.bumpedAt, queuedAt: $0.queuedAt, label: $0.label) },
            running: running.map { RunningJob(id: $0.id, resourceClass: $0.resourceClass, estimate: $0.estimate, footprint: $0.footprint, label: $0.label) },
            freeMemory: SystemMemory.free(level: memoryLevel),
            policy: policy
        )
        let now = Daemon.now()
        for id in decision.admit {
            guard let job = jobs[id] else { continue }
            admit(job, now: now)
        }
        for (id, reason) in decision.waiting {
            guard let job = jobs[id] else { continue }
            let text = Scheduler.message(for: reason)
            // Repeat now and then, so a long wait never looks like a hang.
            if text != job.lastWait || now - job.lastWaitSentAt >= 30 {
                var reply = Message(type: "queued")
                reply.text = text
                job.owner?.send(reply)
                job.lastWait = text
                job.lastWaitSentAt = now
            }
        }
    }

    func admit(_ job: Job, now: Double) {
        job.state = .running
        job.startedAt = now
        job.ceiling = Pressure.ceiling(usualPeak: job.usualPeak, physicalMemory: physical, config: job.throttle)
        var reply = Message(type: "admitted")
        reply.job = job.id
        reply.limits = Throttle.limits(memoryLevel: memoryLevel, cpuCount: cpuCount, config: job.throttle)
        reply.text = "starting after \(formatDuration(now - job.queuedAt))"
        job.owner?.send(reply)
        for joiner in job.joiners { joiner.send(.notice("the run this joined is starting")) }
    }

    // MARK: Monitoring

    func tick() {
        let now = Daemon.now()
        memoryLevel = SystemMemory.level()
        ticks += 1
        if ticks % 5 == 0 { reloadConfig() }

        let active = jobs.values.filter { $0.state != .queued }
        if !active.isEmpty {
            let parents = ProcessTree.parents()
            for job in active { sample(job, parents: parents) }
            for job in active where jobs[job.id] != nil { enforceCeiling(job, now: now) }
            relievePressure(now: now)
        }
        schedule()

        if jobs.isEmpty && connectionsAreIdle() {
            if now - idleSince > idleExit { shutdown(reason: "idle") }
        } else {
            idleSince = now
        }
        if ticks % 3600 == 0 { cleanLogs() }
    }

    func connectionsAreIdle() -> Bool {
        connections.values.allSatisfy { $0.job == nil }
    }

    func sample(_ job: Job, parents: [pid_t: pid_t]) {
        guard let child = job.childPid else { return }
        job.tree = ProcessTree.descendants(of: child, parents: parents)
        if job.tree.isEmpty {
            if job.state == .orphaned { complete(job, exitCode: nil, signal: nil, lost: true) }
            return
        }
        job.footprint = ProcessTree.footprint(of: job.tree)
        job.peak = max(job.peak, job.footprint)
    }

    /// Kills a runaway: a job far past its usual peak, or past a hard ceiling.
    func enforceCeiling(_ job: Job, now: Double) {
        if let deadline = job.killDeadline {
            if now >= deadline, !job.tree.isEmpty { ProcessTree.signal(job.tree, SIGKILL) }
            return
        }
        guard job.footprint > job.ceiling else { return }
        let usual = job.usualPeak.map { " (usual ~\(Bytes.format($0)))" } ?? ""
        let reason = "killed \(job.key), exceeded \(Bytes.format(job.ceiling))\(usual)"
        job.killReason = reason
        job.killDeadline = now + 5
        log("#\(job.id) \(job.project): \(reason), at \(Bytes.format(job.footprint))")
        if job.paused { ProcessTree.signal(job.tree, SIGCONT) }
        ProcessTree.signal(job.tree, SIGTERM)
        for connection in job.connections { connection.send(.notice(reason)) }
    }

    /// Pauses the newest job when memory runs out, and resumes jobs once it recovers.
    func relievePressure(now: Double) {
        guard now - lastPressureAction >= 3 else { return }
        let candidates = jobs.values.filter { $0.state != .queued && !$0.tree.isEmpty && $0.killReason == nil }.map {
            Pressure.Candidate(id: $0.id, startedAt: $0.startedAt ?? 0, paused: $0.paused, pausable: $0.pausable)
        }
        let action = Pressure.action(
            memoryLevel: memoryLevel, jobs: candidates,
            pauseBelow: config.machine.pauseBelowPercent, resumeAbove: config.machine.resumeAbovePercent
        )
        switch action {
        case let .pause(id)?:
            guard let job = jobs[id] else { return }
            job.paused = true
            ProcessTree.signal(job.tree, SIGSTOP)
            lastPressureAction = now
            log("#\(id) paused at \(memoryLevel)% free")
            for connection in job.connections {
                connection.send(.notice("paused, memory is low (\(memoryLevel)% free); resumes when it recovers"))
            }
        case let .resume(id)?:
            guard let job = jobs[id] else { return }
            job.paused = false
            ProcessTree.signal(job.tree, SIGCONT)
            lastPressureAction = now
            log("#\(id) resumed at \(memoryLevel)% free")
            for connection in job.connections { connection.send(.notice("resumed")) }
        case nil:
            break
        }
    }

    // MARK: Commands

    func bump(_ target: String) -> Message {
        let trimmed = target.hasPrefix("#") ? String(target.dropFirst()) : target
        let matches: [Job]
        if let number = Int64(trimmed), let job = jobs[number] {
            matches = [job]
        } else if let pid = Int32(trimmed), let job = jobs.values.first(where: { $0.clientPid == pid || $0.childPid == pid }) {
            matches = [job]
        } else {
            matches = jobs.values.filter { "\($0.project) \($0.key)".localizedCaseInsensitiveContains(trimmed) }
        }
        guard matches.count == 1, let job = matches.first else {
            return .error(matches.isEmpty ? "no job matches \(target)" : "\(target) matches \(matches.count) jobs; use a job number")
        }
        var reply = Message(type: "ok")
        if job.state == .queued {
            job.bumpedAt = Daemon.now()
            reply.text = "bumped #\(job.id) \(job.project) \(job.key) to the front of the queue"
            job.owner?.send(.notice("bumped to the front of the queue"))
            schedule()
        } else {
            ProcessTree.foreground(job.tree)
            if job.paused {
                job.paused = false
                ProcessTree.signal(job.tree, SIGCONT)
            }
            reply.text = "#\(job.id) is already running; raised it to normal priority"
        }
        return reply
    }

    func snapshot() -> StatusSnapshot {
        let ordered = Scheduler.order(jobs.values.filter { $0.state == .queued }.map {
            QueuedJob(id: $0.id, resourceClass: $0.resourceClass, estimate: $0.estimate, agent: $0.agent, bumpedAt: $0.bumpedAt, queuedAt: $0.queuedAt)
        }).map(\.id)
        func describe(_ job: Job) -> JobSnapshot {
            JobSnapshot(
                id: job.id, state: job.paused ? "paused" : job.state.rawValue, resourceClass: job.resourceClass,
                project: job.project, key: job.key, cwd: job.cwd, agent: job.agent, estimate: job.estimate,
                footprint: job.state == .queued ? nil : job.footprint, peak: job.peak > 0 ? job.peak : nil,
                paused: job.paused, clientPid: job.clientPid, childPid: job.childPid, queuedAt: job.queuedAt,
                startedAt: job.startedAt, waiting: job.lastWait, joiners: job.joiners.count
            )
        }
        var limits: [String: Int] = [:]
        for (cls, limit) in policy.classLimits { limits[cls.rawValue] = limit }
        return StatusSnapshot(
            memoryLevel: memoryLevel, physicalMemory: physical, reserve: config.machine.reserveBytes, limits: limits,
            running: jobs.values.filter { $0.state != .queued }.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }.map(describe),
            queued: ordered.compactMap { jobs[$0] }.map(describe),
            recent: store.recent(limit: 10),
            daemonPid: getpid()
        )
    }

    // MARK: Housekeeping

    func reloadConfig() {
        let path = ConfigLoader.globalPath(environment: ProcessInfo.processInfo.environment)
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard modified != configModified else { return }
        configModified = modified
        guard let data = FileManager.default.contents(atPath: path) else {
            config = ConfigFile()
            return
        }
        do {
            config = try ConfigFile.decode(data)
            log("loaded \(path)")
        } catch {
            log("ignoring \(ConfigError(path: path, underlying: error))")
        }
    }

    func cleanLogs() {
        let cutoff = Date().addingTimeInterval(-86400)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: paths.logs)) ?? []
        for file in files {
            let path = paths.logs + "/" + file
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if let modified, modified < cutoff { try? FileManager.default.removeItem(atPath: path) }
        }
    }
}
