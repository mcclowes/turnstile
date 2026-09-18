import Testing
@testable import TurnstileCore

struct TopScreenTests {
    func job(_ id: Int64, state: String = "running", paused: Bool = false, held: Bool = false) -> JobSnapshot {
        JobSnapshot(
            id: id, state: state, resourceClass: .test, project: "api", key: "swift test", cwd: "/api", agent: true,
            estimate: Bytes.gb, footprint: state == "queued" ? nil : Bytes.gb / 2, peak: nil, paused: paused, clientPid: 1,
            childPid: nil, queuedAt: 0, startedAt: state == "queued" ? nil : 10, waiting: state == "queued" ? "waiting for a test slot" : nil,
            joiners: 0, held: held, pausedBy: paused ? "you" : nil
        )
    }

    func snapshot(_ running: [JobSnapshot], _ queued: [JobSnapshot] = []) -> StatusSnapshot {
        StatusSnapshot(memoryLevel: 40, physicalMemory: 16 * Bytes.gb, reserve: 2 * Bytes.gb, limits: [:], running: running, queued: queued, recent: [], daemonPid: 1)
    }

    @Test func arrowsAndLettersMapToKeys() {
        #expect(TopScreen.keys([0x1B, 0x5B, 0x41, 0x6A, 0x78, 0x71]) == [.up, .down, .kill, .quit])
        #expect(TopScreen.keys([0x03]) == [.quit])
    }

    @Test func killDoesntClashWithUp() {
        #expect(TopScreen.key(UInt8(ascii: "k")) == .up)
        #expect(TopScreen.key(UInt8(ascii: "x")) == .kill)
    }

    @Test func selectionFollowsTheJobAndClamps() {
        let rows = [job(1), job(2), job(3, state: "queued")]
        #expect(TopScreen.settle(2, in: rows) == 2)
        #expect(TopScreen.settle(9, in: rows) == 1)
        #expect(TopScreen.settle(nil, in: []) == nil)
        #expect(TopScreen.move(3, by: 1, in: rows) == 3)
        #expect(TopScreen.move(1, by: -1, in: rows) == 1)
        #expect(TopScreen.move(1, by: 1, in: rows) == 2)
    }

    @Test func keysToggleBasedOnState() {
        #expect(TopScreen.control(for: .pause, job: job(1)) == .success("pause"))
        #expect(TopScreen.control(for: .pause, job: job(1, paused: true)) == .success("resume"))
        #expect(TopScreen.control(for: .hold, job: job(2, state: "queued")) == .success("hold"))
        #expect(TopScreen.control(for: .hold, job: job(2, state: "queued", held: true)) == .success("unhold"))
        #expect(TopScreen.control(for: .kill, job: job(2, state: "queued")) == .success("kill"))
        guard case .failure = TopScreen.control(for: .pause, job: job(2, state: "queued")) else { Issue.record("pause on a queued job"); return }
        guard case .failure = TopScreen.control(for: .hold, job: job(1)) else { Issue.record("hold on a running job"); return }
    }

    @Test func rendersJobsAndMarksTheSelection() {
        let lines = TopScreen.render(snapshot([job(1, paused: true)], [job(2, state: "queued", held: true)]), selected: 2, now: 70, width: 200, height: 20, footer: "")
        #expect(lines.count == 20)
        #expect(lines.contains { $0.contains("paused (you)") && $0.contains("api swift test") })
        #expect(lines.contains { $0.contains("▸ 2") && $0.contains("held") && $0.hasPrefix("\u{1B}[7m") })
        #expect(lines.contains { $0.contains("#2 waiting for a test slot") })
        #expect(lines[18] == TopScreen.help)
    }

    @Test func idleDaemonIsNotAnError() {
        let lines = TopScreen.render(nil, selected: nil, now: 0, width: 80, height: 10, footer: "")
        #expect(lines[0].contains("daemon idle"))
    }

    @Test func clipsToTheTerminalWidthKeepingEscapes() {
        #expect(TopScreen.clip("abcdef", to: 3) == "abc")
        #expect(TopScreen.clip("\u{1B}[7mabcdef\u{1B}[0m", to: 2) == "\u{1B}[7mab\u{1B}[0m")
        #expect(TopScreen.render(snapshot([job(1)]), selected: 1, now: 0, width: 30, height: 12, footer: "").allSatisfy { TopScreen.clip($0, to: 30) == $0 })
    }
}
