import Foundation
import SQLite3
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

    @Test
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
    @Test func recordsHowCloseAJobCameToPausing() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Store(path: path)
        let id = store.insertJob(state: "queued", resourceClass: .test, key: "swift test", root: "/a", cwd: "/a", argv: ["swift", "test"], agent: true, clientPid: 1, estimate: 0, now: 1)
        let memory = JobMemory(minLevel: 12, maxPressure: .warn, pausedFor: 30, wouldPause: true)
        store.markFinished(id, outcome: "ok", exitCode: 0, signal: nil, peak: nil, memory: memory, now: 2)
        #expect(store.memory(of: id) == memory)

        let bare = store.insertJob(state: "queued", resourceClass: .test, key: "swift test", root: "/a", cwd: "/a", argv: ["swift", "test"], agent: true, clientPid: 1, estimate: 0, now: 3)
        store.markFinished(bare, outcome: "ok", exitCode: 0, signal: nil, peak: nil, now: 4)
        #expect(store.memory(of: bare) == JobMemory())
    }

    @Test func addsMemoryColumnsToAnOlderDatabase() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        sqlite3_exec(db, "CREATE TABLE jobs (id INTEGER PRIMARY KEY AUTOINCREMENT, state TEXT NOT NULL, class TEXT NOT NULL, key TEXT NOT NULL, root TEXT NOT NULL, cwd TEXT NOT NULL, argv TEXT NOT NULL, agent INTEGER NOT NULL, client_pid INTEGER, child_pid INTEGER, estimate INTEGER, peak INTEGER, exit_code INTEGER, signal INTEGER, outcome TEXT, joined_to INTEGER, queued_at REAL NOT NULL, started_at REAL, finished_at REAL)", nil, nil, nil)
        sqlite3_close(db)
        let store = try Store(path: path)
        let id = store.insertJob(state: "queued", resourceClass: .test, key: "k", root: "/a", cwd: "/a", argv: [], agent: true, clientPid: 1, estimate: 0, now: 1)
        store.markFinished(id, outcome: "ok", exitCode: 0, signal: nil, peak: nil, ranFor: 5, memory: JobMemory(minLevel: 40), now: 2)
        #expect(store.memory(of: id)?.minLevel == 40)
    }

    @Test func learnsUsualPeakPerProject() throws {
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
        #expect(store.usualPeak(key: "swift test", root: "/a") == nil)
        record(root: "/a", peak: 1 * Bytes.gb, at: 2)
        record(root: "/a", peak: 2 * Bytes.gb, at: 3)
        record(root: "/a", peak: 9 * Bytes.gb, outcome: "killed", at: 4)
        #expect(store.usualPeak(key: "swift test", root: "/a") == 2 * Bytes.gb)
        #expect(store.recent(limit: 10).count == 4)
        #expect(store.recent(limit: 10).first?.outcome == "killed")
    }

    @Test func firstRunsInAProjectTakeTheMedianFromOthers() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Store(path: path)
        func record(root: String, peak: UInt64, at time: Double) {
            let id = store.insertJob(state: "queued", resourceClass: .compile, key: "swift build", root: root, cwd: root, argv: ["swift", "build"], agent: true, clientPid: 1, estimate: 0, now: time)
            store.markFinished(id, outcome: "ok", exitCode: 0, signal: nil, peak: peak, now: time + 1)
        }
        #expect(store.typicalPeak(key: "swift build", excluding: "/a") == nil)
        record(root: "/b", peak: 600 * Bytes.mb, at: 1)
        record(root: "/c", peak: 2400 * Bytes.mb, at: 2)
        record(root: "/d", peak: 500 * Bytes.mb, at: 3)
        record(root: "/a", peak: 9 * Bytes.gb, at: 4)
        #expect(store.typicalPeak(key: "swift build", excluding: "/a") == 600 * Bytes.mb)
        record(root: "/e", peak: 800 * Bytes.mb, at: 5)
        #expect(store.typicalPeak(key: "swift build", excluding: "/a") == 700 * Bytes.mb)
    }

    @Test func learnsUsualDurationFromSuccessfulRuns() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Store(path: path)
        func record(root: String = "/a", ranFor: Double?, outcome: String = "ok", at time: Double) {
            let id = store.insertJob(state: "queued", resourceClass: .test, key: "swift test", root: root, cwd: root, argv: ["swift", "test"], agent: true, clientPid: 1, estimate: 0, now: time)
            store.markFinished(id, outcome: outcome, exitCode: 0, signal: nil, peak: nil, ranFor: ranFor, now: time + 1)
        }
        #expect(store.usualDuration(key: "swift test", root: "/a") == nil)
        record(root: "/b", ranFor: 500, at: 1)
        record(ranFor: nil, at: 2)
        #expect(store.usualDuration(key: "swift test", root: "/a") == nil)
        record(ranFor: 90, at: 3)
        record(ranFor: 30, at: 4)
        record(ranFor: 5, outcome: "failed", at: 5)
        record(ranFor: 60, at: 6)
        #expect(store.usualDuration(key: "swift test", root: "/a") == 60)
        record(ranFor: 40, at: 7)
        #expect(store.usualDuration(key: "swift test", root: "/a") == 50)
    }

    @Test func addsTheDurationColumnToAnOlderDatabase() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        sqlite3_exec(db, """
            CREATE TABLE jobs (id INTEGER PRIMARY KEY AUTOINCREMENT, state TEXT NOT NULL, class TEXT NOT NULL, key TEXT NOT NULL,
            root TEXT NOT NULL, cwd TEXT NOT NULL, argv TEXT NOT NULL, agent INTEGER NOT NULL, client_pid INTEGER, child_pid INTEGER,
            estimate INTEGER, peak INTEGER, exit_code INTEGER, signal INTEGER, outcome TEXT, joined_to INTEGER,
            queued_at REAL NOT NULL, started_at REAL, finished_at REAL)
            """, nil, nil, nil)
        sqlite3_close(db)
        let store = try Store(path: path)
        let id = store.insertJob(state: "queued", resourceClass: .test, key: "k", root: "/a", cwd: "/a", argv: [], agent: true, clientPid: 1, estimate: 0, now: 1)
        store.markFinished(id, outcome: "ok", exitCode: 0, signal: nil, peak: nil, ranFor: 12, now: 2)
        #expect(store.usualDuration(key: "k", root: "/a") == 12)
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

    static func makeRepo() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "one\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]] {
            _ = Workspace.git(args, cwd: root, deadline: .distantFuture)
        }
        return Workspace.git(["rev-parse", "--show-toplevel"], cwd: root, deadline: .distantFuture)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? root
    }

    @Test func fingerprintFollowsUncommittedChanges() throws {
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let clean = Workspace.inspect(cwd: root, argv: ["swift", "build"])
        #expect(clean.root == root)
        #expect(clean.fingerprint != nil)
        #expect(Workspace.inspect(cwd: root, argv: ["swift", "build"]).fingerprint == clean.fingerprint)

        try "two\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        #expect(Workspace.inspect(cwd: root, argv: ["swift", "build"]).fingerprint != clean.fingerprint)
    }

    @Test func slowGitGivesUpOnTheFingerprintButKeepsTheRoot() throws {
        let root = try Self.makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace.inspect(cwd: root, argv: ["swift", "build"], budget: 0)
        #expect(workspace.root == root)
        #expect(workspace.fingerprint == nil)
    }
}

struct ProcessDetailTests {
    @Test func readsItsOwnProcess() {
        let me = getpid()
        let table = ProcessTree.table()
        #expect(table[me]?.parent == getppid())
        #expect(table[me]?.name.isEmpty == false)
        #expect(ProcessTree.executable(me)?.isEmpty == false)
        #expect(ProcessTree.arguments(me)?.isEmpty == false)
        #expect(ProcessTree.workingDirectory(me) == FileManager.default.currentDirectoryPath)
    }

    @Test func readsAnotherProcessesDirectoryAndArguments() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp")
        try process.run()
        defer { process.terminate() }
        usleep(200_000)
        let pid = process.processIdentifier
        #expect(ProcessTree.workingDirectory(pid) == "/private/tmp")
        #expect(ProcessTree.arguments(pid)?.dropFirst().first == "5")
    }

    @Test func namesTheAncestorsItCanSee() {
        let chain = ProcessTree.chain(from: getppid(), table: ProcessTree.table())
        #expect(!chain.isEmpty)
        #expect(chain.count <= 8)
    }
}
