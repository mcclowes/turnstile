import Foundation
import Testing
@testable import TurnstileCore

struct SystemTests {
    @Test func readsMemoryLevel() {
        let level = SystemMemory.level(environment: [:])
        #expect((0...100).contains(level))
        #expect(SystemMemory.physical > Bytes.gb)
    }

    @Test func levelCanBeFaked() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("level-\(UUID().uuidString)")
        try "7\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(SystemMemory.level(environment: ["TURNSTILE_MEMORY_LEVEL_FILE": file.path]) == 7)
    }

    @Test func measuresAProcessTree() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 5 & sleep 5; wait"]
        try process.run()
        defer { process.terminate() }
        usleep(200_000)
        let tree = ProcessTree.descendants(of: process.processIdentifier, parents: ProcessTree.parents())
        #expect(tree.count == 3)
        #expect(ProcessTree.footprint(of: tree) > 0)
        ProcessTree.signal(tree, SIGKILL)
    }

    /// macOS 15 resets the creator to launchd's on reparenting; macOS 26 keeps it.
    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26))
    func lineageSurvivesReparentingAndSetsid() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("lineage-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The inner shell starts a setsid'd sleeper and exits, so the sleeper is reparented to launchd.
        process.arguments = ["-c", "sh -c '/usr/bin/python3 -c \"import os, time; os.setsid(); time.sleep(5)\" & echo $$ $! > \(pidFile); sleep 0.5'; sleep 5"]
        try process.run()
        defer { process.terminate() }
        usleep(300_000)
        let pids = try String(contentsOfFile: pidFile, encoding: .utf8).split(separator: " ").compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let (inner, sleeper) = (pids[0], pids[1])
        defer { kill(sleeper, SIGKILL) }
        let innerLineage = try #require(ProcessTree.lineage(inner))
        #expect(ProcessTree.lineage(process.processIdentifier)?.id == innerLineage.creator)
        usleep(900_000)
        #expect(ProcessTree.parents()[sleeper] == 1)
        #expect(ProcessTree.lineage(sleeper)?.creator == innerLineage.id)
    }

    @Test func descendantsOfAMissingProcessIsEmpty() {
        #expect(ProcessTree.descendants(of: 999_999, parents: [:]).isEmpty)
    }
}

struct StoreTests {
    @Test func learnsUsualPeakPerProjectThenAcrossProjects() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Store(path: path)
        func record(root: String, peak: UInt64, outcome: String = "ok", at time: Double) {
            let id = store.insertJob(state: "queued", resourceClass: .test, key: "swift test", root: root, cwd: root, argv: ["swift", "test"], agent: true, clientPid: 1, estimate: 0, now: time)
            store.markStarted(id, childPid: 2, now: time)
            store.markFinished(id, outcome: outcome, exitCode: 0, signal: nil, peak: peak, now: time + 1)
        }
        #expect(store.usualPeak(key: "swift test", root: "/a") == nil)
        record(root: "/b", peak: 3 * Bytes.gb, at: 1)
        #expect(store.usualPeak(key: "swift test", root: "/a") == 3 * Bytes.gb)
        record(root: "/a", peak: 1 * Bytes.gb, at: 2)
        record(root: "/a", peak: 2 * Bytes.gb, at: 3)
        record(root: "/a", peak: 9 * Bytes.gb, outcome: "killed", at: 4)
        #expect(store.usualPeak(key: "swift test", root: "/a") == 2 * Bytes.gb)
        #expect(store.recent(limit: 10).count == 4)
        #expect(store.recent(limit: 10).first?.outcome == "killed")
    }
}

struct StoreRecoveryTests {
    @Test func aCorruptDatabaseIsSetAsideAndReplaced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/state.sqlite"
        try Data(repeating: 0x5A, count: 8192).write(to: URL(fileURLWithPath: path))

        let (store, setAside) = try Store.openOrReset(path: path, now: 1000)
        #expect(setAside == path + ".corrupt-1000")
        #expect(FileManager.default.fileExists(atPath: path + ".corrupt-1000"))
        #expect(store.recent(limit: 1).isEmpty)
    }

    @Test func aHealthyDatabaseIsKept() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try Store(path: path)
        _ = first.insertJob(state: "queued", resourceClass: .test, key: "k", root: "/", cwd: "/", argv: [], agent: true, clientPid: 1, estimate: 0, now: 1)
        first.markFinished(1, outcome: "ok", exitCode: 0, signal: nil, peak: nil, now: 2)
        let (store, setAside) = try Store.openOrReset(path: path, now: 1000)
        #expect(setAside == nil)
        #expect(store.recent(limit: 5).count == 1)
    }
}

struct AncestryTests {
    let parents: [pid_t: pid_t] = [10: 1, 20: 10, 30: 20, 40: 1]

    @Test func findsTheJobAProcessDescendsFrom() {
        #expect(ProcessTree.ancestor(of: 30, among: [10, 40], parents: parents) == 10)
        #expect(ProcessTree.ancestor(of: 10, among: [10], parents: parents) == 10)
        #expect(ProcessTree.ancestor(of: 40, among: [10], parents: parents) == nil)
    }

    @Test func survivesCyclesAndUnknownPids() {
        #expect(ProcessTree.ancestor(of: 5, among: [10], parents: [5: 6, 6: 5]) == nil)
        #expect(ProcessTree.ancestor(of: 999, among: [10], parents: parents) == nil)
    }
}

struct FingerprintInputTests {
    @Test func environmentThatChangesResultsIsPartOfTheFingerprint() {
        let inputs = Workspace.environmentInputs(["CI": "1", "NODE_ENV": "test", "RUN_E2E_TESTS": "1", "HOME": "/x", "TERM": "xterm"])
        #expect(inputs == ["CI=1", "NODE_ENV=test", "RUN_E2E_TESTS=1"])
    }
}
