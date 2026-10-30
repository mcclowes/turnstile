import Darwin
import Foundation
import Testing

@testable import TurnstileCore
@testable import turnstile

struct ObservationTests {
    func cli(_ arguments: [String], home: String, profile: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: profile == nil ? ShimRun.binary() : "/usr/bin/sandbox-exec")
        process.arguments = profile.map { ["-p", $0, ShimRun.binary()] + arguments } ?? arguments
        process.environment = [
            "HOME": home, "TURNSTILE_HOME": home, "TURNSTILE_CONFIG_DIR": home + "/config", "PATH": "/usr/bin:/bin",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == (arguments.first == "doctor" ? 1 : 0))
        return output
    }

    @Test func deniedObservationsNeverClaimAbsenceOrHealthyMemory() throws {
        let home = "/tmp/ts-observation-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let daemon = FakeDaemon(socket: Paths(home: home).socket) { _, _, _, hangUp in hangUp() }
        _ = try #require(Client.connect(socketPath: Paths(home: home).socket))
        _ = daemon
        let profile = "(version 1)(allow default)(deny network*)(deny sysctl-read)"
        let output = try cli(["status", "--json"], home: home, profile: profile)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(json["daemon"] is NSNull)
        #expect(json["observation"] as? String == "permissionDenied")
        let memory = try #require(json["memoryObservation"] as? [String: Any])
        #expect(memory["level"] == nil)
        #expect(memory["physical"] == nil)
        #expect((memory["errors"] as? [String: String])?["kern.memorystatus_level"] != nil)

        let text = try cli(["status"], home: home, profile: profile)
        #expect(text.contains("permission denied"))
        #expect(text.contains("memory: unknown"))
        #expect(text.contains("100% free") == false)
        let doctor = try cli(["doctor"], home: home, profile: profile)
        #expect(doctor.contains("memory    unknown"))
        #expect(doctor.contains("100% free") == false)
        #expect(doctor.contains("exact Unix socket"))
    }

    @Test func missingSocketIsVerifiedAbsence() throws {
        let home = "/tmp/ts-absent-" + UUID().uuidString.prefix(8)
        let output = try cli(["status", "--json"], home: home)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(json["daemon"] as? Bool == false)
        #expect(json["observation"] as? String == "absent")
    }
    @Test func reachableStatusKeepsTheSnapshotContract() throws {
        let (run, _) = try ShimRun.run(cliArguments: ["status", "--json"]) { paths in
            FakeDaemon(socket: paths.socket) { _, _, send, _ in
                var reply = Message(type: "status")
                reply.status = StatusSnapshot(
                    memoryLevel: 73, physicalMemory: 16 * Bytes.gb, reserve: Bytes.gb, limits: [:],
                    running: [], queued: [], recent: [], daemonPid: 123)
                send(reply)
            }
        }
        let snapshot = try JSONDecoder().decode(StatusSnapshot.self, from: Data(run.stdout.utf8))
        #expect(snapshot.daemonPid == 123)
        #expect(snapshot.memoryLevel == 73)
        #expect(snapshot.memoryObservation == nil)
    }

    @Test func connectedWithoutAStatusReplyIsUnreachable() throws {
        let (run, _) = try ShimRun.run(cliArguments: ["status", "--json"]) { paths in
            FakeDaemon(socket: paths.socket) { _, _, _, hangUp in hangUp() }
        }
        let json = try #require(JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        #expect(json["daemon"] is NSNull)
        #expect(json["observation"] as? String == "unreachable")
    }

    @Test func doctorPrefersDaemonMemoryWhenLocalSysctlsAreDenied() throws {
        let home = "/tmp/ts-source-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fake = FakeDaemon(socket: Paths(home: home).socket) { _, _, send, _ in
            var reply = Message(type: "status")
            var snapshot = StatusSnapshot(
                memoryLevel: 37, physicalMemory: 32 * Bytes.gb, reserve: Bytes.gb, limits: [:],
                running: [], queued: [], recent: [], daemonPid: 123)
            snapshot.memoryObservation = MemoryObservation(
                source: "daemon", sampledAt: 1234, level: 37, physical: 32 * Bytes.gb,
                kernelPressure: 2, swapUsed: 33 * Bytes.gb)
            reply.status = snapshot
            send(reply)
        }
        _ = fake
        let text = try cli(["doctor"], home: home, profile: "(version 1)(allow default)(deny sysctl-read)")
        #expect(text.contains("37% free"))
        #expect(text.contains("swap 33 GB used"))
        #expect(text.contains("FAIL  memory"))
        #expect(text.contains("source daemon, sampled at 1234"))
        #expect(text.contains("source local") == false)
    }

    @Test func statusIncludesTheDaemonsCheckedObservation() throws {
        let harness = try DaemonHarness()
        harness.daemon.readMemory()
        let snapshot = harness.daemon.snapshot()
        let memory = try #require(snapshot.memoryObservation)
        #expect(memory.source == "daemon")
        #expect(try #require(memory.sampledAt) > 0)
        #expect(memory.effectivePressure != nil)
        #expect(snapshot.memoryLevel == memory.schedulingSample(at: 0).level)
    }

    @Test func invalidSocketPathIsUnknown() throws {
        let result = Client.connecting(socketPath: "/tmp/" + String(repeating: "a", count: 200))
        guard case .failure(let failure) = result else {
            Issue.record("An oversized socket path unexpectedly connected")
            return
        }
        #expect(failure.observation == "unknown")
        #expect(failure.code == ENAMETOOLONG)
    }

    @Test func doctorAcceptsAHealthyObservation() throws {
        let observation = MemoryObservation(
            source: "daemon", sampledAt: 42, level: 82, physical: 32 * Bytes.gb,
            kernelPressure: 1, swapUsed: 0)
        let findings = Doctor.system(environment: [:], config: Config(), memory: observation)
        let memory = try #require(findings.first { $0.topic == "memory" })
        #expect(memory.level == .ok)
        #expect(memory.text.contains("82% free"))
        #expect(memory.fix == nil)
    }

}
