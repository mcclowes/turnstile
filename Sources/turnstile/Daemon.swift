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
        /// A write failed or timed out part-way, so the stream can't be trusted; the daemon drops it.
        var broken = false
        var onBroken: (() -> Void)?

        init(fd: Int32) { self.fd = fd }

        func send(_ message: Message) {
            guard !broken else { return }
            let data = message.encoded()
            let complete = data.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += written
                }
                return true
            }
            if !complete {
                broken = true
                onBroken?()
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
        let estimateSource: String?
        let usualPeak: UInt64?
        let throttle: ThrottleConfig
        let pausable: Bool
        let queuedAt: Double
        /// Monotonic; wall-clock times are only for history and display.
        let queuedTick = Daemon.clock()
        var admittedTick: Double?
        let captures: Bool
        let interactive: Bool
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
        var paused = false {
            didSet {
                guard paused != oldValue else { return }
                let now = Daemon.clock()
                if paused { pausedTick = now } else if let since = pausedTick { pausedFor += now - since; pausedTick = nil }
            }
        }
        var pausedTick: Double?
        var pausedFor: Double = 0
        var usualDuration: Double?
        /// Started under an earlier daemon, so its run time here is unknown.
        var adopted = false
        /// Paused by a person, so it's never resumed automatically.
        var pausedByUser = false
        /// Held by a person: stays queued until released.
        var held = false
        /// Killed by a person, so callers are told not to retry.
        var cancelled = false
        var killReason: String?
        var killDeadline: Double?
        var lastWait: String?
        var lastWaitSentAt: Double = 0
        var tree: [pid_t] = []
        /// Unique ids of every process seen in the tree, to recognise children that escape to launchd.
        var lineage: Set<UInt64> = []
        var escapees: Set<pid_t> = []

        init(id: Int64, request: Message, cost: Cost, now: Double) {
            self.id = id
            resourceClass = request.resourceClass ?? .compile
            key = request.key ?? request.tool ?? "?"
            root = request.root ?? request.cwd ?? "/"
            cwd = request.cwd ?? root
            argv = request.argv ?? []
            agent = request.agent ?? true
            clientPid = request.pid ?? 0
            fingerprint = request.fingerprint
            estimate = cost.estimate
            estimateSource = cost.source
            usualPeak = cost.usualPeak
            usualDuration = cost.usualDuration
            throttle = ThrottleConfig(
                inject: request.inject, jobs: request.throttleJobs, nodeHeap: request.nodeHeap,
                maxMemory: request.maxMemory, killMultiplier: request.killMultiplier
            )
            pausable = request.pausable ?? agent
            captures = request.captures ?? false
            interactive = request.interactive ?? false
            queuedAt = now
        }

        var project: String { projectName(root) }
        var label: String { "\(project) \(key), ~\(Bytes.format(max(estimate, peak)))" }
        /// Same command in the same place, whatever the tree's contents.
        var identity: String { ([root, cwd] + argv).joined(separator: "\u{0}") }
        var connections: [Connection] { (owner.map { [$0] } ?? []) + joiners }

        /// Seconds spent running since admission, not counting time paused.
        func ranFor(now: Double) -> Double? {
            guard let admittedTick else { return nil }
            return now - admittedTick - pausedFor - (pausedTick.map { now - $0 } ?? 0)
        }
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
    /// launchd's children, and who created them. Nil when unreadable (another user's).
    var orphanLineage: [pid_t: ProcessTree.Lineage?] = [:]
    var ticks = 0
    var lastPressureAction: Double = 0
    var idleSince = Daemon.clock()
    let idleExit: Double
    let physical = SystemMemory.physical
    let cpuCount = SystemMemory.cpuCount

    init(paths: Paths, idleExit: Double) throws {
        self.paths = paths
        self.idleExit = idleExit
        try paths.ensure()
        let (store, setAside) = try Store.openOrReset(path: paths.database, now: Daemon.now())
        self.store = store
        if let setAside { log("history database was unreadable; moved it to \(setAside) and started fresh") }
    }

    static func now() -> Double { Date().timeIntervalSince1970 }
    static func clock() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

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
            // `release` tells clients this stop is deliberate, so they carry on rather than restart the daemon.
            var message = Message(type: "release")
            message.text = job.state == .queued ? "daemon stopped; running ungated" : "daemon stopped; continuing untracked"
            for connection in job.connections { connection.send(message) }
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
        // A client that stops reading (say, suspended with Ctrl-Z) mustn't stall the whole daemon.
        var limit = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let connection = Connection(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.read(connection)
        }
        source.setCancelHandler { close(fd) }
        connection.source = source
        // Deferred, since a send can fail in the middle of changing job state.
        connection.onBroken = { [weak self, weak connection] in
            DispatchQueue.main.async {
                guard let self, let connection, self.connections[ObjectIdentifier(connection)] != nil else { return }
                self.log("dropping a client that stopped reading")
                self.disconnected(connection)
            }
        }
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
        case "adopt": adopt(message, from: connection)
        case "started": started(message, from: connection)
        case "finished": finished(message, from: connection)
        case "status":
            var reply = Message(type: "status")
            reply.status = snapshot()
            connection.send(reply)
        case "bump", "kill", "pause", "resume", "hold", "unhold":
            connection.send(control(message.type, target: message.target ?? ""))
        case "stop":
            connection.send(Message(type: "ok"))
            shutdown(reason: "requested")
        default:
            connection.send(.error("unknown message \(message.type)"))
        }
    }

    func request(_ message: Message, from connection: Connection) {
        // A shim started inside a running job whose environment was scrubbed of its token would otherwise wait on its own parent.
        if let pid = message.pid, let parent = runningJob(containing: pid) {
            var reply = Message(type: "release")
            reply.job = parent.id
            connection.send(reply)
            return
        }
        let now = Daemon.now()
        let key = message.key ?? message.tool ?? "?"
        let root = message.root ?? message.cwd ?? "/"
        let cost = cost(of: message, key: key, root: root)
        let id = store.insertJob(
            state: "queued", resourceClass: message.resourceClass ?? .compile, key: key, root: root,
            cwd: message.cwd ?? root, argv: message.argv ?? [], agent: message.agent ?? true,
            clientPid: message.pid ?? 0, estimate: cost.estimate, now: now
        )
        let job = Job(id: id, request: message, cost: cost, now: now)
        connection.job = id

        // The same command on the same tree contents joins the run in progress.
        if let fingerprint = job.fingerprint,
           let twin = jobs.values.first(where: { canJoin(job, $0, fingerprint: fingerprint) }) {
            attach(connection, to: twin, text: "joining an identical \(twin.key) already \(twin.state == .queued ? "queued" : "running") in \(twin.project) (#\(twin.id))")
            store.markJoined(id, to: twin.id, outcome: "joined", exitCode: nil, now: now)
            connection.job = twin.id
            return
        }

        jobs[id] = job
        job.owner = connection

        // A newer request from the same worktree replaces its queued one; the older caller gets this run's result.
        for stale in jobs.values where job.captures && stale.id != id && stale.state == .queued && stale.identity == job.identity {
            jobs.removeValue(forKey: stale.id)
            if stale.held { job.held = true }
            for follower in stale.connections {
                attach(follower, to: job, text: "superseded by a newer \(job.key) from this worktree (#\(job.id)); reporting its result")
            }
            store.markJoined(stale.id, to: id, outcome: "superseded", exitCode: nil, now: now)
        }

        idleSince = Daemon.clock()
        schedule()
    }

    struct Cost {
        var estimate: UInt64
        var source: String?
        /// This project's history only; runaway limits shouldn't come from another project.
        var usualPeak: UInt64?
        var usualDuration: Double?
    }

    /// Config first, then this project's history, then other projects', then the class default.
    func cost(of request: Message, key: String, root: String) -> Cost {
        var cost = memoryCost(of: request, key: key, root: root)
        cost.usualDuration = store.usualDuration(key: key, root: root)
        return cost
    }

    private func memoryCost(of request: Message, key: String, root: String) -> Cost {
        let usual = store.usualPeak(key: key, root: root)
        if let memory = request.memory { return Cost(estimate: memory, source: "config", usualPeak: usual) }
        if let usual { return Cost(estimate: usual, usualPeak: usual) }
        if let typical = store.typicalPeak(key: key, excluding: root) {
            return Cost(estimate: typical, source: "other projects", usualPeak: nil)
        }
        return Cost(estimate: (request.resourceClass ?? .compile).defaultEstimate, source: "the class default", usualPeak: nil)
    }

    /// Only merge with a run whose output can be followed, that behaves the same way, and that still has an owner.
    func canJoin(_ job: Job, _ twin: Job, fingerprint: String) -> Bool {
        twin.fingerprint == fingerprint && twin.root == job.root && twin.killReason == nil
            && twin.state != .orphaned && twin.owner != nil && twin.captures && twin.interactive == job.interactive
    }

    func runningJob(containing pid: pid_t) -> Job? {
        let running = jobs.values.filter { $0.state != .queued && $0.childPid != nil }
        guard !running.isEmpty else { return nil }
        let roots = Set(running.compactMap(\.childPid))
        guard let root = ProcessTree.ancestor(of: pid, among: roots, parents: ProcessTree.parents()) else { return nil }
        return running.first { $0.childPid == root }
    }

    /// A job already running when its daemon died re-registers, so the new daemon counts its slot and memory.
    func adopt(_ message: Message, from connection: Connection) {
        guard let child = message.childPid, ProcessTree.isAlive(child) else {
            connection.send(Message(type: "ok"))
            return
        }
        var request = message
        request.fingerprint = nil
        let now = Daemon.now()
        let key = request.key ?? request.tool ?? "?"
        let root = request.root ?? request.cwd ?? "/"
        let cost = cost(of: request, key: key, root: root)
        let id = store.insertJob(
            state: "running", resourceClass: request.resourceClass ?? .compile, key: key, root: root,
            cwd: request.cwd ?? root, argv: request.argv ?? [], agent: request.agent ?? true,
            clientPid: request.pid ?? 0, estimate: cost.estimate, now: now
        )
        store.markStarted(id, childPid: child, now: now)
        let job = Job(id: id, request: request, cost: cost, now: now)
        job.state = .running
        job.startedAt = now
        job.admittedTick = Daemon.clock()
        job.adopted = true
        job.usualDuration = nil
        job.childPid = child
        job.log = request.log
        job.owner = connection
        job.ceiling = Pressure.ceiling(usualPeak: cost.usualPeak, physicalMemory: physical, config: job.throttle)
        jobs[id] = job
        connection.job = id
        log("#\(id) adopted \(job.project) \(job.key), pid \(child), after a daemon restart")
        var reply = Message(type: "ok")
        reply.job = id
        connection.send(reply)
        sample(job, parents: ProcessTree.parents())
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
        if job.cancelled { outcome = "cancelled" }
        else if job.killReason != nil { outcome = "killed" }
        else if lost { outcome = "lost" }
        else if exitCode == 0 { outcome = "ok" }
        else if signal != nil { outcome = "signaled" }
        else { outcome = "failed" }
        if job.paused { ProcessTree.signal(job.tree, SIGCONT) }
        let ranFor = job.adopted ? nil : job.ranFor(now: Daemon.clock())
        store.markFinished(job.id, outcome: outcome, exitCode: exitCode, signal: signal, peak: job.peak > 0 ? job.peak : nil, ranFor: ranFor, now: now)
        log("#\(job.id) \(job.project) \(job.key): \(outcome), peak \(Bytes.format(job.peak))")

        var done = Message(type: "done")
        done.job = job.id
        done.exitCode = exitCode
        done.signal = signal
        if job.cancelled { done.cancelled = true }
        if lost { done.text = "the run this joined ended without a result" }
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
            done.text = "the run this joined was cancelled"
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
        return SchedulerPolicy(classLimits: limits, reserve: config.machine.reserveBytes, backfillMax: SchedulerPolicy.backfillMax(physicalMemory: physical))
    }

    func schedule() {
        let queued = jobs.values.filter { $0.state == .queued }
        guard !queued.isEmpty else { return }
        let running = jobs.values.filter { $0.state != .queued }
        let clock = Daemon.clock()
        let decision = Scheduler.decide(
            queue: queued.map { QueuedJob(id: $0.id, resourceClass: $0.resourceClass, estimate: $0.estimate, agent: $0.agent, bumpedAt: $0.bumpedAt, queuedAt: $0.queuedTick, label: $0.label, held: $0.held, duration: $0.usualDuration) },
            running: running.map {
                RunningJob(id: $0.id, resourceClass: $0.resourceClass, estimate: $0.estimate, footprint: $0.footprint, label: $0.label,
                           usualDuration: $0.paused ? nil : $0.usualDuration, elapsed: $0.ranFor(now: clock) ?? 0)
            },
            freeMemory: SystemMemory.free(level: memoryLevel),
            policy: policy,
            now: clock
        )
        let now = Daemon.now()
        let tick = Daemon.clock()
        for id in decision.admit {
            guard let job = jobs[id] else { continue }
            admit(job, now: now, ahead: decision.skipped[id])
        }
        for (id, reason) in decision.waiting {
            guard let job = jobs[id] else { continue }
            let text = reason == .held ? "held; `turnstile release #\(id)` lets it run" : Scheduler.message(for: reason)
            // Repeat now and then, so a long wait never looks like a hang.
            if text != job.lastWait || tick - job.lastWaitSentAt >= 30 {
                var reply = Message(type: "queued")
                reply.text = text
                job.owner?.send(reply)
                job.lastWait = text
                job.lastWaitSentAt = tick
            }
        }
    }

    func admit(_ job: Job, now: Double, ahead blocker: String? = nil) {
        job.state = .running
        job.startedAt = now
        job.admittedTick = Daemon.clock()
        job.ceiling = Pressure.ceiling(usualPeak: job.usualPeak, physicalMemory: physical, config: job.throttle)
        var reply = Message(type: "admitted")
        reply.job = job.id
        reply.limits = Throttle.limits(memoryLevel: memoryLevel, cpuCount: cpuCount, config: job.throttle)
        let skipped = blocker.map { ", ahead of \($0), which is waiting for memory" } ?? ""
        reply.text = "starting after \(formatDuration(now - job.queuedAt))\(skipped)"
        job.owner?.send(reply)
        for joiner in job.joiners { joiner.send(.notice("the run this joined is starting")) }
    }

    // MARK: Monitoring

    func tick() {
        let now = Daemon.clock()
        memoryLevel = SystemMemory.level()
        ticks += 1
        if ticks % 5 == 0 { reloadConfig() }

        let active = jobs.values.filter { $0.state != .queued }
        if !active.isEmpty {
            let parents = ProcessTree.parents()
            let escaped = escapedRoots(parents: parents, active: active)
            for job in active { sample(job, parents: parents, escaped: escaped[job.id] ?? []) }
            for job in active where jobs[job.id] != nil { enforceCeiling(job, now: now) }
            relievePressure(now: now)
            reclaimUnstarted(now: now)
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

    /// `escaped` are processes that left the job's tree for launchd, such as build servers; they still count against it.
    func sample(_ job: Job, parents: [pid_t: pid_t], escaped: [pid_t] = []) {
        guard let child = job.childPid else { return }
        let previous = Set(job.tree)
        let own = ProcessTree.descendants(of: child, parents: parents)
        if own.isEmpty {
            job.tree = []
            if job.state == .orphaned { complete(job, exitCode: nil, signal: nil, lost: true) }
            return
        }
        var tree = own
        var included = Set(own)
        for root in escaped where included.insert(root).inserted {
            if job.escapees.insert(root).inserted { log("#\(job.id) pid \(root) left the job for launchd; still counting it") }
            tree.append(root)
            for pid in ProcessTree.descendants(of: root, parents: parents) where included.insert(pid).inserted { tree.append(pid) }
        }
        job.tree = tree
        let fresh = tree.filter { !previous.contains($0) }
        for pid in fresh { if let lineage = ProcessTree.lineage(pid) { job.lineage.insert(lineage.id) } }
        // Anything a paused job spawned just before it stopped is paused too.
        if job.paused && !fresh.isEmpty { ProcessTree.signal(fresh, SIGSTOP) }
        job.footprint = ProcessTree.footprint(of: job.tree)
        job.peak = max(job.peak, job.footprint)
    }

    /// Children of launchd that a running job created, found by their creator's unique id, which survives reparenting and setsid.
    func escapedRoots(parents: [pid_t: pid_t], active: [Job]) -> [Int64: [pid_t]] {
        var owners: [UInt64: Int64] = [:]
        for job in active { for id in job.lineage { owners[id] = job.id } }
        let orphans = parents.compactMap { $0.value == 1 ? $0.key : nil }
        let live = Set(orphans)
        orphanLineage = orphanLineage.filter { live.contains($0.key) }
        guard !owners.isEmpty else { return [:] }
        var result: [Int64: [pid_t]] = [:]
        for pid in orphans {
            let lineage: ProcessTree.Lineage?
            if let cached = orphanLineage[pid] {
                lineage = cached
            } else {
                lineage = ProcessTree.lineage(pid)
                orphanLineage[pid] = lineage
            }
            if let creator = lineage?.creator, let owner = owners[creator] { result[owner, default: []].append(pid) }
        }
        return result
    }

    /// An admitted client that never starts its job (suspended, or frozen by its harness) mustn't hold a slot forever.
    func reclaimUnstarted(now: Double) {
        for job in jobs.values where job.state == .running && job.childPid == nil {
            guard let admitted = job.admittedTick, now - admitted > 15 else { continue }
            log("#\(job.id) \(job.project) \(job.key): admitted 15s ago but never started; freeing its slot")
            job.owner?.job = nil
            complete(job, exitCode: nil, signal: nil, lost: true)
        }
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
            Pressure.Candidate(id: $0.id, startedAt: $0.admittedTick ?? 0, paused: $0.paused, pausable: $0.pausable, manual: $0.pausedByUser)
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

    /// A job by number, pid, or a unique piece of its name.
    func resolve(_ target: String) -> Result<Job, ControlError> {
        let trimmed = target.hasPrefix("#") ? String(target.dropFirst()) : target
        let matches: [Job]
        if let number = Int64(trimmed), let job = jobs[number] {
            matches = [job]
        } else if let pid = Int32(trimmed), let job = jobs.values.first(where: { $0.clientPid == pid || $0.childPid == pid }) {
            matches = [job]
        } else {
            matches = trimmed.isEmpty ? [] : jobs.values.filter { "\($0.project) \($0.key)".localizedCaseInsensitiveContains(trimmed) }
        }
        guard matches.count == 1, let job = matches.first else {
            return .failure(ControlError(text: matches.isEmpty ? "no job matches \(target)" : "\(target) matches \(matches.count) jobs; use a job number"))
        }
        return .success(job)
    }

    struct ControlError: Error { let text: String }

    func control(_ action: String, target: String) -> Message {
        let job: Job
        switch resolve(target) {
        case let .success(found): job = found
        case let .failure(error): return .error(error.text)
        }
        let name = "#\(job.id) \(job.project) \(job.key)"
        let text: String
        switch action {
        case "bump": text = bump(job, name: name)
        case "kill": text = kill(job, name: name)
        case "pause":
            guard job.state != .queued else { return .error("\(name) hasn't started; use `turnstile hold` to keep it from starting") }
            guard !job.tree.isEmpty else { return .error("\(name) is starting; try again in a moment") }
            let wasPaused = job.paused
            job.paused = true
            job.pausedByUser = true
            if !wasPaused { ProcessTree.signal(job.tree, SIGSTOP) }
            log("#\(job.id) paused by request")
            for connection in job.connections { connection.send(.notice("paused by you; `turnstile resume #\(job.id)` to carry on")) }
            text = wasPaused ? "\(name) was already paused; it now stays paused until you resume it" : "paused \(name)"
        case "resume":
            guard job.paused else { return .error("\(name) isn't paused") }
            job.paused = false
            job.pausedByUser = false
            ProcessTree.signal(job.tree, SIGCONT)
            log("#\(job.id) resumed by request")
            for connection in job.connections { connection.send(.notice("resumed")) }
            text = "resumed \(name)"
        case "hold":
            guard job.state == .queued else { return .error("\(name) is already running; use `turnstile pause` instead") }
            guard !job.held else { return .error("\(name) is already held") }
            job.held = true
            job.lastWait = nil
            text = "holding \(name); `turnstile release #\(job.id)` lets it run"
            schedule()
        default:  // unhold
            guard job.held else { return .error("\(name) isn't held") }
            job.held = false
            job.lastWait = nil
            text = "released \(name)"
            schedule()
        }
        var reply = Message(type: "ok")
        reply.text = text
        return reply
    }

    func bump(_ job: Job, name: String) -> String {
        if job.state == .queued {
            job.bumpedAt = Daemon.clock()
            job.owner?.send(.notice("bumped to the front of the queue"))
            schedule()
            return "bumped \(name) to the front of the queue" + (job.held ? " (still held; release it to run)" : "")
        }
        ProcessTree.foreground(job.tree)
        if job.paused {
            job.paused = false
            job.pausedByUser = false
            ProcessTree.signal(job.tree, SIGCONT)
        }
        guard job.resourceClass == .compile else { return "#\(job.id) is already running, at utility priority, which can't be raised" }
        return "#\(job.id) is already running; raised it to normal priority"
    }

    /// Drops a queued job, or stops a running one: SIGTERM now, SIGKILL after a grace period. Joiners share its fate.
    func kill(_ job: Job, name: String) -> String {
        let affected = job.joiners.count
        let others = affected == 0 ? "" : " and \(affected) joined run\(affected == 1 ? "" : "s")"
        var cancelled = Message(type: "cancelled")
        cancelled.text = Turnstile.cancelledText
        cancelled.job = job.id
        job.cancelled = true
        log("#\(job.id) \(job.project) \(job.key): killed by request")
        if job.state == .queued {
            jobs.removeValue(forKey: job.id)
            store.markFinished(job.id, outcome: "cancelled", exitCode: nil, signal: nil, peak: nil, now: Daemon.now())
            var done = Message(type: "done")
            done.job = job.id
            done.cancelled = true
            done.text = Turnstile.cancelledText
            for connection in job.connections {
                connection.send(cancelled)
                connection.send(done)
                connection.job = nil
            }
            schedule()
            return "cancelled queued \(name)\(others)"
        }
        guard job.killReason == nil else { return "\(name) is already being stopped" }
        job.killReason = Turnstile.cancelledText
        job.killDeadline = Daemon.clock() + 5
        if job.paused { ProcessTree.signal(job.tree, SIGCONT) }
        ProcessTree.signal(job.tree, SIGTERM)
        for connection in job.connections { connection.send(cancelled) }
        return "killed \(name)\(others)"
    }

    func snapshot() -> StatusSnapshot {
        let ordered = Scheduler.order(jobs.values.filter { $0.state == .queued }.map {
            QueuedJob(id: $0.id, resourceClass: $0.resourceClass, estimate: $0.estimate, agent: $0.agent, bumpedAt: $0.bumpedAt, queuedAt: $0.queuedTick, held: $0.held)
        }).map(\.id)
        func describe(_ job: Job) -> JobSnapshot {
            JobSnapshot(
                id: job.id, state: job.paused ? "paused" : job.state.rawValue, resourceClass: job.resourceClass,
                project: job.project, key: job.key, cwd: job.cwd, agent: job.agent, estimate: job.estimate,
                footprint: job.state == .queued ? nil : job.footprint, peak: job.peak > 0 ? job.peak : nil,
                paused: job.paused, clientPid: job.clientPid, childPid: job.childPid, queuedAt: job.queuedAt,
                startedAt: job.startedAt, waiting: job.lastWait, joiners: job.joiners.count,
                held: job.held, pausedBy: job.paused ? (job.pausedByUser ? "you" : "memory") : nil,
                estimateSource: job.estimateSource
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
            for warning in ConfigLint.warnings(data, scope: .global) { log("config: \(warning)") }
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
