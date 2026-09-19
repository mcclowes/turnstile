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

    @Test func aRunawayIsTerminatedThenKilled() throws {
        let harness = try DaemonHarness()
        let owner = FakeClient()
        // Ignores SIGTERM, so only the SIGKILL after the grace period ends it.
        let tool = try harness.sleeper("trap '' TERM; while true; do sleep 1; done")
        let id = harness.request(owner)
        harness.started(owner, childPid: tool.processIdentifier)
        let job = try #require(harness.job(id))
        job.ceiling = 1
        job.footprint = 2

        let now = Daemon.clock()
        harness.daemon.enforceCeiling(job, now: now)
        #expect(job.killReason?.hasPrefix("killed swift build, exceeded") == true)
        #expect(owner.received().contains { $0.type == "notice" && $0.text == job.killReason })
        usleep(200_000)
        #expect(tool.isRunning)

        harness.daemon.enforceCeiling(job, now: now + 6)
        tool.waitUntilExit()
        #expect(tool.terminationReason == .uncaughtSignal)
    }
}
