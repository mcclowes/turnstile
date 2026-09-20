import Darwin
import Foundation
import Testing
@testable import turnstile
@testable import TurnstileCore

@Suite(.serialized)
struct DaemonAdmissionTests {
    @Test func admitsAtOnceWhenASlotAndMemoryAreFree() throws {
        let harness = try DaemonHarness()
        let client = FakeClient()
        let id = harness.request(client)
        let replies = client.received()
        #expect(replies.map(\.type) == ["admitted"])
        #expect(replies.first?.job == id)
        #expect(harness.job(id)?.state == .running)
    }

    @Test func waitsForAFreeSlotAndSaysWhy() throws {
        let harness = try DaemonHarness()
        let first = FakeClient(), second = FakeClient()
        harness.request(first, key: "swift test", resourceClass: .test)
        let id = harness.request(second, key: "swift test", resourceClass: .test, root: "/other")
        let waiting = second.received()
        #expect(waiting.map(\.type) == ["queued"])
        #expect(waiting.first?.text?.contains("waiting for a test slot") == true)

        harness.finished(first)
        #expect(second.types() == ["admitted"])
        #expect(harness.job(id)?.state == .running)
    }

    @Test func waitsForMemory() throws {
        let harness = try DaemonHarness(memoryLevel: 50)
        let first = FakeClient(), second = FakeClient()
        harness.request(first, memory: harness.physical / 4)
        harness.request(second, memory: harness.physical / 2, root: "/other")
        let waiting = second.received()
        #expect(waiting.map(\.type) == ["queued"])
        #expect(waiting.first?.text?.contains("waiting for memory") == true)
    }

    @Test func peopleGoAheadOfAgents() throws {
        let harness = try DaemonHarness()
        let running = FakeClient(), agent = FakeClient(), person = FakeClient()
        harness.request(running, key: "swift test", resourceClass: .test)
        harness.request(agent, key: "swift test", resourceClass: .test, root: "/agent")
        harness.request(person, key: "swift test", resourceClass: .test, agent: false, root: "/person")
        _ = agent.received()
        _ = person.received()

        harness.finished(running)
        #expect(person.types() == ["admitted"])
        #expect(!agent.types().contains("admitted"))
    }

    @Test func bumpMovesAJobToTheFront() throws {
        let harness = try DaemonHarness()
        let running = FakeClient(), older = FakeClient(), newer = FakeClient()
        harness.request(running, key: "swift test", resourceClass: .test)
        harness.request(older, key: "swift test", resourceClass: .test, root: "/older")
        let bumped = harness.request(newer, key: "swift test", resourceClass: .test, root: "/newer")
        #expect(harness.control("bump", "\(bumped!)").type == "ok")

        harness.finished(running)
        #expect(newer.received().contains { $0.type == "admitted" })
        #expect(!older.types().contains("admitted"))
    }

    @Test func heldJobsWaitUntilReleased() throws {
        let harness = try DaemonHarness()
        let running = FakeClient(), held = FakeClient()
        harness.request(running, key: "swift test", resourceClass: .test)
        let id = harness.request(held, key: "swift test", resourceClass: .test, root: "/held")
        #expect(harness.control("hold", "\(id!)").type == "ok")
        harness.finished(running)
        #expect(!held.types().contains("admitted"))

        #expect(harness.control("unhold", "\(id!)").type == "ok")
        #expect(held.types().contains("admitted"))
    }

    @Test func aNestedCallInsideARunningJobIsReleased() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient(), nested = FakeClient()
        let shell = try harness.sleeper()
        harness.request(owner)
        harness.started(owner, childPid: shell.processIdentifier)

        let child = ProcessTree.descendants(of: shell.processIdentifier, parents: ProcessTree.parents())
            .first { $0 != shell.processIdentifier }
        try #require(child != nil)
        harness.request(nested, root: "/nested", pid: child)
        #expect(nested.types() == ["release"])
        #expect(harness.daemon.jobs.count == 1)
    }
}

@Suite(.serialized)
struct DaemonMergingTests {
    @Test func anIdenticalRunJoinsAndGetsItsResult() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient(), joiner = FakeClient()
        let id = harness.request(owner, fingerprint: "abc")
        harness.request(joiner, fingerprint: "abc")
        let joined = joiner.received()
        #expect(joined.map(\.type) == ["joined"])
        #expect(joined.first?.job == id)
        #expect(harness.daemon.jobs.count == 1)

        harness.finished(owner, exitCode: 3)
        let done = joiner.received().last
        #expect(done?.type == "done")
        #expect(done?.exitCode == 3)
    }

    @Test func runsWithoutFollowableOutputDontMerge() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient(), other = FakeClient()
        harness.request(owner, fingerprint: "abc", captures: false)
        harness.request(other, fingerprint: "abc")
        #expect(other.types() == ["admitted"])
        #expect(harness.daemon.jobs.count == 2)
    }

    @Test func differentTreesDontMerge() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient(), other = FakeClient()
        harness.request(owner, fingerprint: "abc")
        harness.request(other, fingerprint: "def")
        #expect(other.types() == ["admitted"])
    }

    @Test func aNewerRequestFromTheSameWorktreeSupersedesTheQueuedOne() throws {
        let harness = try DaemonHarness()
        let running = FakeClient(), stale = FakeClient(), fresh = FakeClient()
        harness.request(running, key: "swift test", resourceClass: .test, root: "/busy")
        let staleID = harness.request(stale, key: "swift test", resourceClass: .test, fingerprint: "v1")
        let freshID = harness.request(fresh, key: "swift test", resourceClass: .test, fingerprint: "v2")
        #expect(harness.job(staleID) == nil)
        #expect(stale.received().contains { $0.type == "joined" && $0.job == freshID })

        harness.finished(running)
        #expect(fresh.types().contains("admitted"))
        harness.finished(fresh, exitCode: 1)
        #expect(stale.received().last?.exitCode == 1)
    }

    @Test func aQueuedOwnerLeavingTellsItsJoinersToRunThemselves() throws {
        let harness = try DaemonHarness()
        let running = FakeClient(), owner = FakeClient(), joiner = FakeClient()
        harness.request(running, key: "swift test", resourceClass: .test, root: "/busy")
        let id = harness.request(owner, key: "swift test", resourceClass: .test, fingerprint: "abc")
        harness.request(joiner, key: "swift test", resourceClass: .test, fingerprint: "abc")
        _ = joiner.received()

        harness.daemon.disconnected(owner.connection)
        #expect(harness.job(id) == nil)
        let done = joiner.received().last
        #expect(done?.type == "done")
        #expect(done?.exitCode == nil && done?.signal == nil)
    }
}

@Suite(.serialized)
struct DaemonLifecycleTests {
    @Test func finishedRunsTeachTheNextEstimate() throws {
        let harness = try DaemonHarness()
        let first = FakeClient(), second = FakeClient()
        let id = harness.request(first, memory: nil)
        harness.job(id)?.peak = 700 * Bytes.mb
        harness.finished(first)

        let next = harness.request(second, memory: nil)
        #expect(harness.job(next)?.estimate == 700 * Bytes.mb)
        #expect(harness.job(next)?.estimateSource == nil)
    }

    @Test func outcomesAreRecorded() throws {
        let harness = try DaemonHarness()
        for (exit, signal, outcome) in [(Int32?(0), Int32?.none, "ok"), (1, nil, "failed"), (nil, SIGTERM, "signaled")] {
            let client = FakeClient()
            let id = harness.request(client, root: "/\(outcome)")
            harness.finished(client, exitCode: exit, signal: signal)
            let recorded = harness.daemon.store.recent(limit: 10).first { $0.id == id }
            #expect(recorded?.outcome == outcome)
        }
    }

    @Test func aClientThatDiesWhileItsJobRunsKeepsTheSlotUntilTheJobExits() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient()
        let tool = try harness.sleeper()
        let id = harness.request(owner)
        harness.started(owner, childPid: tool.processIdentifier)

        harness.daemon.disconnected(owner.connection)
        #expect(harness.job(id)?.state == .orphaned)

        tool.terminate()
        tool.waitUntilExit()
        harness.daemon.sample(harness.job(id)!, parents: ProcessTree.parents())
        #expect(harness.job(id) == nil)
    }

    @Test func aClientThatDiesBeforeItsJobStartsFreesTheSlot() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient()
        let id = harness.request(owner)
        harness.daemon.disconnected(owner.connection)
        #expect(harness.job(id) == nil)
    }

    @Test func anAdmittedJobThatNeverStartsIsReclaimed() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient()
        let id = harness.request(owner)
        harness.daemon.reclaimUnstarted(now: Daemon.clock())
        #expect(harness.job(id) != nil)

        harness.job(id)?.admittedTick = Daemon.clock() - 16
        harness.daemon.reclaimUnstarted(now: Daemon.clock())
        #expect(harness.job(id) == nil)
    }

    @Test func adoptionCountsAJobFromAnEarlierDaemon() throws {
        let harness = try DaemonHarness()
        let tool = try harness.sleeper()
        let client = FakeClient()
        var adopt = Message(type: "adopt")
        adopt.key = "swift build"
        adopt.resourceClass = .compile
        adopt.root = "/repo"
        adopt.childPid = tool.processIdentifier
        harness.daemon.handle(adopt, from: client.connection)
        let reply = client.received().last
        #expect(reply?.type == "ok")
        let job = harness.job(reply?.job)
        #expect(job?.state == .running)
        #expect(job?.adopted == true)
        #expect(job?.tree.contains(tool.processIdentifier) == true)
    }

    @Test func adoptingAJobThatAlreadyExitedIsANoOp() throws {
        let harness = try DaemonHarness()
        let client = FakeClient()
        var adopt = Message(type: "adopt")
        adopt.childPid = 999_999
        harness.daemon.handle(adopt, from: client.connection)
        #expect(client.received().last?.job == nil)
        #expect(harness.daemon.jobs.isEmpty)
    }
}

@Suite(.serialized)
struct DaemonControlTests {
    @Test func killingAQueuedJobCancelsItAndItsJoiners() throws {
        let harness = try DaemonHarness()
        let running = FakeClient(), owner = FakeClient(), joiner = FakeClient()
        harness.request(running, key: "swift test", resourceClass: .test, root: "/busy")
        let id = harness.request(owner, key: "swift test", resourceClass: .test, fingerprint: "abc")
        harness.request(joiner, key: "swift test", resourceClass: .test, fingerprint: "abc")
        _ = owner.received(); _ = joiner.received()

        let reply = harness.control("kill", "\(id!)")
        #expect(reply.text?.contains("and 1 joined run") == true)
        #expect(harness.job(id) == nil)
        for client in [owner, joiner] {
            let messages = client.received()
            #expect(messages.map(\.type) == ["cancelled", "done"])
            #expect(messages.last?.cancelled == true)
        }
    }

    @Test func killingARunningJobTerminatesItsTree() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient()
        let tool = try harness.sleeper()
        let id = harness.request(owner)
        harness.started(owner, childPid: tool.processIdentifier)

        #expect(harness.control("kill", "\(id!)").type == "ok")
        #expect(owner.received().contains { $0.type == "cancelled" })
        tool.waitUntilExit()
        #expect(tool.terminationReason == .uncaughtSignal)
        harness.finished(owner, exitCode: nil, signal: SIGTERM)
        #expect(harness.daemon.store.recent(limit: 1).first?.outcome == "cancelled")
    }

    @Test func pauseAndResumeStopAndContinueTheTree() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient()
        let tool = try harness.sleeper()
        let id = harness.request(owner)
        harness.started(owner, childPid: tool.processIdentifier)

        #expect(harness.control("pause", "\(id!)").type == "ok")
        #expect(DaemonHarness.state(tool.processIdentifier).hasPrefix("T"))
        #expect(harness.job(id)?.pausedByUser == true)

        #expect(harness.control("resume", "\(id!)").type == "ok")
        #expect(!DaemonHarness.state(tool.processIdentifier).hasPrefix("T"))
    }

    @Test func controlsRefuseWhatDoesntApply() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient()
        let id = harness.request(owner)
        #expect(harness.control("hold", "\(id!)").type == "error")
        #expect(harness.control("resume", "\(id!)").type == "error")
        #expect(harness.control("kill", "nothing-matches").type == "error")
    }

    @Test func jobsResolveByNumberPidOrUniqueName() throws {
        let harness = try DaemonHarness()
        let build = FakeClient(), test = FakeClient()
        let buildID = harness.request(build, root: "/api", pid: 4242)
        harness.request(test, key: "swift test", resourceClass: .test, root: "/web")

        guard case let .success(byNumber) = harness.daemon.resolve("#\(buildID!)") else { Issue.record("by number"); return }
        #expect(byNumber.id == buildID)
        guard case let .success(byPid) = harness.daemon.resolve("4242") else { Issue.record("by pid"); return }
        #expect(byPid.id == buildID)
        guard case let .success(byName) = harness.daemon.resolve("web") else { Issue.record("by name"); return }
        #expect(byName.key == "swift test")
        guard case .failure = harness.daemon.resolve("swift") else { Issue.record("ambiguous name resolved"); return }
    }
}

@Suite(.serialized)
struct DaemonPressureTests {
    @Test func theNewestAgentJobIsPausedUnderPressureAndResumedAfter() throws {
        let harness = try DaemonHarness()
        let older = FakeClient(), newer = FakeClient()
        let olderTool = try harness.sleeper(), newerTool = try harness.sleeper()
        let olderID = harness.request(older, root: "/older")
        harness.started(older, childPid: olderTool.processIdentifier)
        let newerID = harness.request(newer, root: "/newer")
        harness.started(newer, childPid: newerTool.processIdentifier)
        harness.job(olderID)?.admittedTick = Daemon.clock() - 60

        harness.daemon.memoryLevel = 4
        harness.daemon.relievePressure(now: Daemon.clock())
        #expect(harness.job(newerID)?.paused == true)
        #expect(harness.job(olderID)?.paused == false)
        #expect(DaemonHarness.state(newerTool.processIdentifier).hasPrefix("T"))
        #expect(newer.received().contains { $0.text?.hasPrefix("paused, memory is low") == true })

        harness.daemon.memoryLevel = 50
        harness.daemon.relievePressure(now: Daemon.clock() + 10)
        #expect(harness.job(newerID)?.paused == false)
        #expect(!DaemonHarness.state(newerTool.processIdentifier).hasPrefix("T"))
    }

    @Test func recordsHowCloseEachJobCameToPausing() throws {
        let harness = try DaemonHarness()
        let older = FakeClient(), newer = FakeClient()
        let olderTool = try harness.sleeper(), newerTool = try harness.sleeper()
        let olderID = harness.request(older, root: "/older")
        harness.started(older, childPid: olderTool.processIdentifier)
        let newerID = harness.request(newer, root: "/newer")
        harness.started(newer, childPid: newerTool.processIdentifier)
        harness.job(olderID)?.admittedTick = Daemon.clock() - 60

        harness.daemon.observe(MemoryReading(level: 30, pressure: .warn, swapUsed: 0))
        harness.daemon.relievePressure(now: Daemon.clock() + 10)
        #expect(harness.job(newerID)?.paused == false)
        harness.daemon.observe(MemoryReading(level: 60, pressure: .normal, swapUsed: 0))
        harness.finished(newer)
        #expect(harness.daemon.store.memory(of: newerID!) == JobMemory(minLevel: 30, maxPressure: .warn, wouldPause: true))

        _ = harness.control("pause", "\(olderID!)")
        usleep(50_000)
        harness.finished(older)
        let recorded = harness.daemon.store.memory(of: olderID!)
        #expect(recorded?.wouldPause == false)
        #expect((recorded?.pausedFor ?? 0) > 0)
    }

    @Test func jobsAPersonPausedArentResumedAutomatically() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient()
        let tool = try harness.sleeper()
        let id = harness.request(owner)
        harness.started(owner, childPid: tool.processIdentifier)
        _ = harness.control("pause", "\(id!)")

        harness.daemon.memoryLevel = 80
        harness.daemon.relievePressure(now: Daemon.clock() + 10)
        #expect(harness.job(id)?.paused == true)
    }

    /// #17: the level stays healthy while the machine swaps, because swapping is what holds it up.
    @Test func swappingPausesEvenWhileTheLevelLooksHealthy() throws {
        let harness = try DaemonHarness()
        let older = FakeClient(), newer = FakeClient()
        let olderTool = try harness.sleeper(), newerTool = try harness.sleeper()
        let olderID = harness.request(older, root: "/older")
        harness.started(older, childPid: olderTool.processIdentifier)
        let newerID = harness.request(newer, root: "/newer")
        harness.started(newer, childPid: newerTool.processIdentifier)
        harness.job(olderID)?.admittedTick = Daemon.clock() - 60

        harness.daemon.memoryLevel = 35
        harness.daemon.relievePressure(now: Daemon.clock())
        #expect(harness.job(newerID)?.paused == false)

        harness.daemon.memoryPressure = .swapping
        harness.daemon.relievePressure(now: Daemon.clock() + 10)
        #expect(harness.job(newerID)?.paused == true)
        #expect(DaemonHarness.state(newerTool.processIdentifier).hasPrefix("T"))
        #expect(newer.received().contains { $0.text == "paused, the machine is swapping; resumes when it recovers" })

        harness.daemon.memoryPressure = .normal
        harness.daemon.relievePressure(now: Daemon.clock() + 20)
        #expect(harness.job(newerID)?.paused == false)
    }

    @Test func nothingIsAdmittedWhileTheMachineSwaps() throws {
        let harness = try DaemonHarness()
        let running = FakeClient(), waiting = FakeClient()
        let tool = try harness.sleeper()
        harness.request(running)
        harness.started(running, childPid: tool.processIdentifier)

        harness.daemon.memoryPressure = .swapping
        let queued = harness.request(waiting, root: "/other")
        #expect(harness.job(queued)?.state == .queued)
        #expect(waiting.received().contains { $0.text?.hasPrefix("waiting, the machine is swapping") == true })

        harness.daemon.memoryPressure = .normal
        harness.daemon.schedule()
        #expect(harness.job(queued)?.state == .running)
    }

    @Test func peoplesJobsArentPausedForMemory() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient()
        let tool = try harness.sleeper()
        let id = harness.request(owner, agent: false, pausable: false)
        harness.started(owner, childPid: tool.processIdentifier)

        harness.daemon.memoryLevel = 3
        harness.daemon.relievePressure(now: Daemon.clock())
        #expect(harness.job(id)?.paused == false)
    }

    /// The soak (`scripts/pressure-soak.sh`) checks that every process a pause stopped is in state T.
    /// Walking the tree from outside can't find escapees, so status reports the tree the daemon signals.
    @Test func statusReportsTheTreeAPauseWouldStop() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient()
        let tool = try harness.sleeper()
        let id = harness.request(owner)
        harness.started(owner, childPid: tool.processIdentifier)
        let job = try #require(harness.job(id))
        let escapee: pid_t = 999_999
        job.tree = [tool.processIdentifier, escapee]
        job.escapees = [escapee]

        let running = try #require(harness.daemon.snapshot().running.first)
        #expect(running.tree == [tool.processIdentifier, escapee])
        #expect(running.escapees == [escapee])
    }

    /// An explicit `maxMemory` is the one place a person asked for a kill, so it doesn't wait for pressure.
    @Test func aHardMemoryLimitIsTerminatedThenKilled() throws {
        let harness = try DaemonHarness(memoryLevel: 90)
        let owner = FakeClient()
        // Ignores SIGTERM, so only the SIGKILL after the grace period ends it.
        let tool = try harness.sleeper("trap '' TERM; while true; do sleep 1; done")
        let id = harness.request(owner, maxMemory: 1)
        harness.started(owner, childPid: tool.processIdentifier)
        let job = try #require(harness.job(id))
        job.footprint = 2

        let now = Daemon.clock()
        harness.daemon.enforceCeiling(job, now: now)
        #expect(job.killReason?.hasPrefix("killed swift build, exceeded") == true)
        #expect(job.killReason?.contains("retrying won't help") == true)
        #expect(owner.received().contains { $0.type == "notice" && $0.text == job.killReason })
        usleep(200_000)
        #expect(tool.isRunning)

        harness.daemon.enforceCeiling(job, now: now + 6)
        tool.waitUntilExit()
        #expect(tool.terminationReason == .uncaughtSignal)
    }

    /// A build that never went through a shim is recorded, while a job's own processes aren't.
    @Test func noticesHeavyProcessesRunningOutsideEveryJob() throws {
        let harness = try DaemonHarness()
        let client = FakeClient()
        let id = harness.request(client)
        harness.started(client, childPid: 300)
        harness.job(id)?.tree = [300, 301]

        harness.daemon.probe = probe([
            // Xcode's build service compiles without a shell, so nothing can gate it.
            Fake(pid: 500, parent: 400, name: "swift-frontend", executable: "/usr/bin/swift-frontend", args: ["swift-frontend", "-c"], cwd: "/Users/me/app"),
            Fake(pid: 400, parent: 1, name: "SWBBuildService", executable: "/Applications/Xcode.app/SWBBuildService", args: ["SWBBuildService"], cwd: "/"),
            // A compiler inside a gated job, which is already accounted for.
            Fake(pid: 301, parent: 300, name: "swift-frontend", executable: "/usr/bin/swift-frontend", args: ["swift-frontend", "-c"], cwd: "/repo"),
            Fake(pid: 300, parent: 200, name: "swift", executable: "/usr/bin/swift", args: ["swift", "build"], cwd: "/repo"),
            // Not a build at all.
            Fake(pid: 600, parent: 400, name: "node", executable: "/usr/local/bin/node", args: ["node", "/app/server.js"], cwd: "/app"),
        ])

        harness.daemon.watchForEscapes(now: 1000)
        #expect(harness.daemon.store.escapes(since: 0) == [EscapeRow(label: "swift-frontend", via: "Xcode", cwd: "/Users/me/app", count: 1, lastSeen: 1000)])

        // Counted once, not once per scan.
        harness.daemon.watchForEscapes(now: 1001)
        #expect(harness.daemon.store.escapes(since: 0).first?.count == 1)
    }

    @Test func leavesProcessesAJobStartedAlone() throws {
        let harness = try DaemonHarness()
        let client = FakeClient()
        harness.request(client)
        harness.started(client, childPid: 300)
        // The job's tree hasn't been sampled yet, so the ancestry check is what keeps this one out.
        harness.daemon.probe = probe([
            Fake(pid: 301, parent: 300, name: "rustc", executable: "/usr/bin/rustc", args: ["rustc", "src/main.rs"], cwd: "/repo"),
            Fake(pid: 300, parent: 200, name: "cargo", executable: "/usr/bin/cargo", args: ["cargo", "build"], cwd: "/repo"),
        ])
        harness.daemon.watchForEscapes(now: 1000)
        #expect(harness.daemon.store.escapes(since: 0).isEmpty)
    }

    @Test("A sampled child stays attached to its job after launchd adopts it", .bug(id: 49))
    func findsAReparentedProcessByItsOwnIdentity() throws {
        let harness = try DaemonHarness()
        let client = FakeClient()
        let id = try #require(harness.request(client))
        let job = try #require(harness.job(id))
        job.lineage = [9_001]
        harness.daemon.probe.lineage = { pid in
            pid == 500 ? ProcessTree.Lineage(id: 9_001, creator: 1) : nil
        }

        #expect(harness.daemon.escapedRoots(parents: [500: 1], active: [job]) == [id: [500]])
    }

    struct Fake {
        var pid: pid_t
        var parent: pid_t
        var name: String
        var executable: String
        var args: [String]
        var cwd: String
    }

    /// A process table of this user's processes, with each one's unique id derived from its pid.
    func probe(_ processes: [Fake]) -> ProcessProbe {
        let byPid = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        return ProcessProbe(
            table: { byPid.mapValues { ProcessTree.Entry(parent: $0.parent, name: $0.name, uid: getuid()) } },
            executable: { byPid[$0]?.executable },
            arguments: { byPid[$0]?.args },
            workingDirectory: { byPid[$0]?.cwd },
            lineage: { pid in byPid[pid].map { ProcessTree.Lineage(id: UInt64($0.pid), creator: UInt64($0.parent)) } }
        )
    }

    /// The bug from issue #16: a cold rebuild passing the ceiling while most of the machine is free
    /// was killed, and the retry was killed too.
    @Test func aRunawayKeepsRunningWhileMemoryIsPlentiful() throws {
        let harness = try DaemonHarness(memoryLevel: 90)
        let owner = FakeClient()
        let tool = try harness.sleeper()
        let id = harness.request(owner)
        harness.started(owner, childPid: tool.processIdentifier)
        let job = try #require(harness.job(id))
        job.ceiling = 1
        job.footprint = 2

        let now = Daemon.clock()
        harness.daemon.enforceCeiling(job, now: now)
        harness.daemon.enforceCeiling(job, now: now + 60)
        #expect(job.killReason == nil)
        #expect(job.paused == false)
        #expect(tool.isRunning)
        // Said once, so a long run doesn't repeat it every second.
        #expect(owner.received().filter { $0.text?.contains("more memory than usual") == true }.count == 1)
    }

    @Test func aRunawayUnderPressureIsPausedBeforeItIsKilled() throws {
        let harness = try DaemonHarness(memoryLevel: 3)
        let owner = FakeClient()
        let tool = try harness.sleeper()
        let id = harness.request(owner)
        harness.started(owner, childPid: tool.processIdentifier)
        let job = try #require(harness.job(id))
        job.ceiling = 1
        job.footprint = 2

        let now = Daemon.clock()
        harness.daemon.enforceCeiling(job, now: now)
        #expect(job.paused == true)
        #expect(job.killReason == nil)
        #expect(DaemonHarness.state(tool.processIdentifier).hasPrefix("T"))

        // Pressure lifts before the grace period ends, so it's resumed rather than killed.
        harness.daemon.memoryLevel = 50
        harness.daemon.enforceCeiling(job, now: now + 5)
        harness.daemon.relievePressure(now: now + 5)
        #expect(job.paused == false)
        #expect(job.killReason == nil)

        // Back under pressure, and this time it doesn't lift.
        harness.daemon.memoryLevel = 3
        harness.daemon.enforceCeiling(job, now: now + 10)
        #expect(job.paused == true)
        harness.daemon.enforceCeiling(job, now: now + 25)
        #expect(job.killReason?.hasPrefix("killed swift build, exceeded") == true)
        harness.daemon.enforceCeiling(job, now: now + 31)
        tool.waitUntilExit()
        #expect(tool.isRunning == false)
    }
}
