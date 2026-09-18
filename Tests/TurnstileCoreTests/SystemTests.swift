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
