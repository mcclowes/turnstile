import Darwin
import Foundation
import Testing
@testable import turnstile
@testable import TurnstileCore

/// A scripted stand-in for the daemon: listens on the turnstile socket and answers each message with `reply`.
final class FakeDaemon: @unchecked Sendable {
    typealias Reply = (_ message: Message, _ connection: Int, _ send: (Message) -> Void, _ hangUp: () -> Void) -> Void

    private let lock = NSLock()
    private var log: [(connection: Int, message: Message)] = []
    private let listener: Int32
    private let reply: Reply

    init(socket path: String, reply: @escaping Reply) {
        self.reply = reply
        unlink(path)
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8)
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        Darwin.listen(listener, 8)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    /// Messages received so far, with the index of the connection each arrived on.
    var received: [(connection: Int, message: Message)] { lock.withLock { log } }
    var types: [String] { received.map(\.message.type) }

    private func acceptLoop() {
        var index = 0
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            let connection = index
            index += 1
            Thread.detachNewThread { [self] in serve(fd, connection: connection) }
        }
    }

    private func serve(_ fd: Int32, connection: Int) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var lines = LineBuffer()
        var open = true
        var chunk = [UInt8](repeating: 0, count: 65536)
        let send: (Message) -> Void = { message in
            let data = message.encoded()
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        }
        let hangUp = { open = false }
        while open {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            for line in lines.append(Data(chunk[0..<count])) {
                guard let message = Message.decode(line) else { continue }
                lock.withLock { log.append((connection, message)) }
                reply(message, connection, send, hangUp)
                if !open { break }
            }
        }
        close(fd)
    }
}

/// Runs the real binary as a `swift` shim against a fake daemon, with a fake `swift` behind it.
struct ShimRun {
    let exitCode: Int32
    let signaled: Bool
    let stdout: String
    let stderr: String
    let toolRuns: [String]
    /// Runs the shim recorded as ungated.
    let ungated: [UngatedLog.Entry]

    static func binary() -> String {
        Bundle(for: FakeDaemon.self).bundleURL.deletingLastPathComponent().appendingPathComponent("turnstile").path
    }

    /// `daemon` is built once the home, and so the socket path, exists.
    static func run(_ args: [String] = ["build"], environment extra: [String: String] = [:], timeout: Double = 90, daemon: (Paths) -> FakeDaemon) throws -> (ShimRun, FakeDaemon) {
        let root = NSTemporaryDirectory() + "ts-shim-" + UUID().uuidString.prefix(8)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = Paths(home: root + "/home")
        try paths.ensure()
        let bin = root + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let runs = root + "/runs"
        FileManager.default.createFile(atPath: runs, contents: nil)
        let tool = """
            #!/bin/bash
            echo "run $* token=${TURNSTILE_TOKEN:-none}" >> "\(runs)"
            echo "fake swift $*"
            [ -n "${FAKE_SLEEP:-}" ] && exec sleep "$FAKE_SLEEP"
            exit "${FAKE_EXIT:-0}"
            """
        try tool.write(toFile: bin + "/swift", atomically: true, encoding: .utf8)
        chmod(bin + "/swift", 0o755)
        try FileManager.default.createSymbolicLink(atPath: paths.shims + "/swift", withDestinationPath: binary())

        let fake = daemon(paths)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: paths.shims + "/swift")
        process.arguments = args
        var environment = ["PATH": "\(paths.shims):\(bin):/usr/bin:/bin", "HOME": root, "TURNSTILE_HOME": paths.home,
                           "TURNSTILE_CONFIG_DIR": root + "/config", "TURNSTILE_AGENT": "1"]
        environment.merge(extra) { $1 }
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let result = ShimRun(
            exitCode: process.terminationStatus,
            signaled: process.terminationReason == .uncaughtSignal,
            stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            toolRuns: ((try? String(contentsOfFile: runs, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init),
            ungated: UngatedLog.parse((try? String(contentsOfFile: paths.ungatedLog, encoding: .utf8)) ?? "")
        )
        return (result, fake)
    }
}

func reply(_ type: String, job: Int64? = nil, text: String? = nil, exitCode: Int32? = nil) -> Message {
    var message = Message(type: type)
    message.job = job
    message.text = text
    message.exitCode = exitCode
    return message
}

@Suite(.serialized)
struct SupervisorTests {
    @Test func onlyCompileJobsPauseByDefault() {
        #expect(Supervisor.isPausable(agent: true, resourceClass: .compile, configured: nil))
        #expect(!Supervisor.isPausable(agent: true, resourceClass: .test, configured: nil))
        #expect(!Supervisor.isPausable(agent: true, resourceClass: .browser, configured: nil))
        #expect(Supervisor.isPausable(agent: true, resourceClass: .test, configured: true))
        #expect(!Supervisor.isPausable(agent: true, resourceClass: .compile, configured: false))
        #expect(!Supervisor.isPausable(agent: false, resourceClass: .compile, configured: true))
    }

    @Test func waitsThenRunsAndReportsTheResult() throws {
        let (run, daemon) = try ShimRun.run(environment: ["FAKE_EXIT": "3"]) { paths in
            FakeDaemon(socket: paths.socket) { message, _, send, _ in
                switch message.type {
                case "request":
                    send(reply("queued", text: "waiting for a compile slot (running: api swift build)"))
                    send(reply("admitted", job: 7, text: "starting after 1s"))
                case "finished": send(reply("ok"))
                default: break
                }
            }
        }
        #expect(run.exitCode == 3)
        #expect(run.stdout == "fake swift build\n")
        #expect(run.stderr.contains("turnstile: waiting for a compile slot"))
        #expect(run.stderr.contains("turnstile: starting after 1s"))
        #expect(run.toolRuns.count == 1)
        #expect(run.toolRuns.first?.contains("token=7:") == true)

        let request = try #require(daemon.received.first { $0.message.type == "request" }?.message)
        #expect(request.key == "swift build")
        #expect(request.argv == ["swift", "build"])
        #expect(request.agent == true)
        #expect(daemon.received.first { $0.message.type == "started" }?.message.childPid ?? 0 > 0)
        #expect(daemon.received.first { $0.message.type == "finished" }?.message.exitCode == 3)
    }

    @Test func aDaemonErrorRunsTheToolUngated() throws {
        let (run, daemon) = try ShimRun.run { paths in
            FakeDaemon(socket: paths.socket) { message, _, send, _ in
                if message.type == "request" { send(reply("error", text: "something broke")) }
            }
        }
        #expect(run.exitCode == 0)
        #expect(run.stderr.contains("turnstile: something broke"))
        #expect(run.toolRuns.count == 1)
        #expect(!daemon.types.contains("started"))
        #expect(run.ungated.map(\.command) == ["swift build"])
        #expect(run.ungated.first?.cause == "something broke")
    }

    @Test func aReleaseRunsTheToolWithoutReportingBack() throws {
        let (run, daemon) = try ShimRun.run { paths in
            FakeDaemon(socket: paths.socket) { message, _, send, _ in
                if message.type == "request" { send(reply("release")) }
            }
        }
        #expect(run.exitCode == 0)
        #expect(run.stderr.isEmpty)
        #expect(run.toolRuns == ["run build token=none"])
        #expect(daemon.types == ["request"])
        #expect(run.ungated.isEmpty)
    }

    @Test func cancelledWhileWaitingExitsWithoutRunning() throws {
        let (run, _) = try ShimRun.run { paths in
            FakeDaemon(socket: paths.socket) { message, _, send, _ in
                guard message.type == "request" else { return }
                send(reply("queued", text: "waiting"))
                send(reply("cancelled", text: Turnstile.cancelledText))
            }
        }
        #expect(run.exitCode == Turnstile.cancelledExitCode)
        #expect(run.stderr.contains("don't retry"))
        #expect(run.toolRuns.isEmpty)
    }

    @Test func aJoinerExitsWithTheRunsResultWithoutRunning() throws {
        let (run, _) = try ShimRun.run { paths in
            FakeDaemon(socket: paths.socket) { message, _, send, _ in
                guard message.type == "request" else { return }
                send(reply("joined", job: 3, text: "joining an identical swift build"))
                send(reply("done", job: 3, exitCode: 4))
            }
        }
        #expect(run.exitCode == 4)
        #expect(run.stderr.contains("joining an identical swift build"))
        #expect(run.toolRuns.isEmpty)
    }

    @Test func aJoinedRunThatEndsWithoutAResultIsRunHere() throws {
        let (run, daemon) = try ShimRun.run { paths in
            FakeDaemon(socket: paths.socket) { message, connection, send, _ in
                switch (message.type, connection) {
                case ("request", 0):
                    send(reply("joined", job: 3))
                    send(reply("done", job: 3, text: "the run this joined was cancelled"))
                case ("request", _): send(reply("admitted", job: 9))
                case ("finished", _): send(reply("ok"))
                default: break
                }
            }
        }
        #expect(run.exitCode == 0)
        #expect(run.stderr.contains("running it here instead"))
        #expect(run.toolRuns.count == 1)
        #expect(daemon.types.filter { $0 == "request" }.count == 2)
    }

    @Test func cancelledWhileRunningStopsTheTool() throws {
        let (run, _) = try ShimRun.run(environment: ["FAKE_SLEEP": "30"]) { paths in
            FakeDaemon(socket: paths.socket) { message, _, send, _ in
                switch message.type {
                case "request": send(reply("admitted", job: 5))
                case "started": send(reply("cancelled", job: 5, text: Turnstile.cancelledText))
                case "finished": send(reply("ok"))
                default: break
                }
            }
        }
        // Well inside the tool's 30s sleep, so it was stopped rather than waited out.
        #expect(!run.signaled)
        #expect(run.exitCode == Turnstile.cancelledExitCode)
    }

    @Test func aRunningJobReRegistersWhenItsDaemonDies() throws {
        let (run, daemon) = try ShimRun.run(environment: ["FAKE_SLEEP": "1"]) { paths in
            FakeDaemon(socket: paths.socket) { message, _, send, hangUp in
                switch message.type {
                case "request": send(reply("admitted", job: 5))
                case "started": hangUp()
                case "adopt": send(reply("ok", job: 6))
                case "finished": send(reply("ok"))
                default: break
                }
            }
        }
        #expect(run.exitCode == 0)
        let adopt = try #require(daemon.received.first { $0.message.type == "adopt" })
        #expect(adopt.connection == 1)
        #expect(adopt.message.childPid == daemon.received.first { $0.message.type == "started" }?.message.childPid)
        #expect(daemon.received.contains { $0.message.type == "finished" && $0.connection == 1 })
    }

    /// Slow: the shim gives a silent daemon 10 seconds.
    @Test func aSilentDaemonIsGivenUpOn() throws {
        let (run, _) = try ShimRun.run { paths in
            FakeDaemon(socket: paths.socket) { _, _, _, _ in }
        }
        #expect(run.exitCode == 0)
        #expect(run.stderr.contains("the daemon stopped answering"))
        #expect(run.toolRuns.count == 1)
        #expect(run.ungated.first?.cause == "the daemon stopped answering")
    }
}

@Suite(.serialized)
struct CLILifecycleTests {
    @Test func installingANewerVersionRestartsABusyOlderDaemon() throws {
        let root = NSTemporaryDirectory() + "ts-cli-" + UUID().uuidString.prefix(8)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = Paths(home: root + "/home")
        try paths.ensure()
        let running = JobSnapshot(
            id: 1, state: "running", resourceClass: .compile, project: "repo", key: "swift build",
            cwd: "/repo", agent: true, estimate: Bytes.gb, footprint: Bytes.gb, peak: Bytes.gb,
            paused: false, clientPid: 10, childPid: 11, queuedAt: 1, startedAt: 2, waiting: nil, joiners: 0
        )
        let daemon = FakeDaemon(socket: paths.socket) { message, _, send, hangUp in
            switch message.type {
            case "status":
                var reply = Message(type: "status")
                reply.status = StatusSnapshot(
                    memoryLevel: 50, physicalMemory: 16 * Bytes.gb, reserve: 2 * Bytes.gb,
                    limits: [:], running: [running], queued: [], recent: [], daemonPid: 123,
                    version: "older"
                )
                send(reply)
            case "restart":
                send(reply("ok"))
                hangUp()
            default: break
            }
        }

        CLI.retireOldDaemon(paths: paths)

        #expect(daemon.types == ["status", "restart"])
    }

    @Test func installingANewerVersionStopsAnIdleLegacyDaemon() throws {
        let root = NSTemporaryDirectory() + "ts-cli-" + UUID().uuidString.prefix(8)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = Paths(home: root + "/home")
        try paths.ensure()
        let daemon = FakeDaemon(socket: paths.socket) { message, _, send, hangUp in
            switch message.type {
            case "status":
                var reply = Message(type: "status")
                reply.status = StatusSnapshot(
                    memoryLevel: 50, physicalMemory: 16 * Bytes.gb, reserve: 2 * Bytes.gb,
                    limits: [:], running: [], queued: [], recent: [], daemonPid: 123,
                    version: "legacy"
                )
                send(reply)
            case "restart": send(.error("unknown message restart"))
            case "stop":
                send(reply("ok"))
                hangUp()
            default: break
            }
        }

        CLI.retireOldDaemon(paths: paths)

        #expect(daemon.types == ["status", "restart", "stop"])
    }
}
