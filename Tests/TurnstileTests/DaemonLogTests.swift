import Foundation
import Testing
@testable import turnstile
@testable import TurnstileCore

@Suite(.serialized)
struct DaemonLogTests {
    func write(_ path: String, age: Double = 0) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("output\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }

    @Test func aRunningJobCarriesItsLog() throws {
        let harness = try DaemonHarness()
        let captured = FakeClient(), terminal = FakeClient()
        let capturedID = harness.request(captured)
        let terminalID = harness.request(terminal, captures: false, root: "/other")
        harness.started(captured, childPid: getpid(), log: harness.daemon.paths.log(forJob: capturedID!))
        harness.started(terminal, childPid: getpid())

        let running = harness.daemon.snapshot().running
        #expect(running.first { $0.id == capturedID }?.log == harness.daemon.paths.log(forJob: capturedID!))
        #expect(running.first { $0.id == terminalID }?.log == nil)
    }

    @Test func aRecentRunCarriesItsLogOnlyWhileTheFileExists() throws {
        let harness = try DaemonHarness()
        let kept = FakeClient(), gone = FakeClient()
        let keptID = harness.request(kept)
        harness.finished(kept, exitCode: 1)
        let goneID = harness.request(gone, root: "/other")
        harness.finished(gone, exitCode: 1)
        try write(harness.daemon.paths.log(forJob: keptID!))

        let recent = harness.daemon.snapshot().recent
        #expect(recent.first { $0.id == keptID }?.log == harness.daemon.paths.log(forJob: keptID!))
        #expect(recent.first { $0.id == goneID }?.log == nil)
    }

    @Test func cleaningKeepsFailedRunsForAWeek() throws {
        let harness = try DaemonHarness()
        let passed = FakeClient(), failed = FakeClient(), oldFailure = FakeClient()
        let passedID = harness.request(passed)
        harness.finished(passed)
        let failedID = harness.request(failed, root: "/b")
        harness.finished(failed, exitCode: 1)
        let oldID = harness.request(oldFailure, root: "/c")
        harness.finished(oldFailure, exitCode: 1)
        let paths = harness.daemon.paths
        try write(paths.log(forJob: passedID!), age: 2 * 86400)
        try write(paths.log(forJob: failedID!), age: 3 * 86400)
        try write(paths.log(forJob: oldID!), age: 8 * 86400)
        try write(paths.logs + "/stray.txt", age: 2 * 86400)

        harness.daemon.cleanLogs()
        let exists = { FileManager.default.fileExists(atPath: $0) }
        #expect(!exists(paths.log(forJob: passedID!)))
        #expect(exists(paths.log(forJob: failedID!)))
        #expect(!exists(paths.log(forJob: oldID!)))
        #expect(!exists(paths.logs + "/stray.txt"))
    }
}
