import Foundation
import Testing
@testable import TurnstileCore

struct MemoryPressureTests {
    let mb = Bytes.mb
    let gb = Bytes.gb

    func track(_ samples: [MemorySample]) -> MemoryPressureTracker {
        var tracker = MemoryPressureTracker()
        for sample in samples { tracker.record(sample) }
        return tracker
    }

    func sample(_ at: Double, level: Int = 40, kernel: Int = 1, swap: UInt64 = 0) -> MemorySample {
        MemorySample(level: level, kernelPressure: kernel, swapUsed: swap, at: at)
    }

    @Test func aQuietMachineReadsNormal() {
        let samples = (0..<20).map { sample(Double($0), level: 45, swap: 2 * gb) }
        #expect(track(samples).pressure == .normal)
    }

    /// The dev machine in #17 sits at 7.3 GB of swap and reads "warn" all day with room to spare.
    /// Standing swap says where pages have already gone, not whether there is room for a job.
    @Test func standingSwapAndAWarnLevelAreNotPressure() {
        let samples = (0..<20).map { sample(Double($0), level: 37, kernel: 2, swap: 7_300 * mb) }
        #expect(track(samples).pressure == .normal)
    }

    /// Recorded from `scripts/bench.sh` on an M4 with 16 GB (#17): the level stayed near 30% while
    /// the machine swapped 5 GB, so nothing ever paused and four more jobs were admitted.
    @Test func theBenchmarkRunReadsAsSwapping() {
        let recorded: [(Double, Int, UInt64)] = [
            (0, 42, 8_600 * mb),
            (15, 35, 12_000 * mb),
            (30, 16, 12_300 * mb),
            (45, 29, 13_300 * mb),
            (60, 33, 13_800 * mb),
            (75, 35, 14_400 * mb),
        ]
        var tracker = MemoryPressureTracker()
        var readings: [EffectiveMemoryPressure] = []
        for (at, level, swap) in recorded {
            tracker.record(sample(at, level: level, swap: swap))
            readings.append(tracker.pressure)
        }
        #expect(readings.first == .normal)
        #expect(readings.dropFirst().allSatisfy { $0 > .normal })
        #expect(readings.contains(.critical))
    }

    @Test func swapGrowingSlowlyIsStillNormal() {
        let samples = (0..<20).map { sample(Double($0), swap: 4 * gb + UInt64($0) * 8 * mb) }
        #expect(track(samples).pressure == .normal)
    }

    @Test func aCriticalKernelLevelIsCriticalWhateverSwapDoes() {
        #expect(track([sample(0, level: 60, kernel: 4, swap: 0)]).pressure == .critical)
    }

    @Test func growthOlderThanTheWindowIsForgotten() {
        var tracker = MemoryPressureTracker()
        tracker.record(sample(0, swap: 4 * gb))
        tracker.record(sample(10, swap: 6 * gb))
        #expect(tracker.pressure == .critical)
        for step in 1...30 { tracker.record(sample(10 + Double(step), swap: 6 * gb)) }
        #expect(tracker.pressure == .normal)
    }

    /// Growth stays in the window after it stops, so a machine that has just been swapping gets
    /// time to settle before anything new is let in.
    @Test func growthKeepsReadingForTheRestOfTheWindow() {
        var tracker = MemoryPressureTracker()
        tracker.record(sample(0, swap: 4 * gb))
        tracker.record(sample(1, swap: 4 * gb + 512 * mb))
        #expect(tracker.pressure == .swapping)
        for step in 2...15 { tracker.record(sample(Double(step), swap: 4 * gb + 512 * mb)) }
        #expect(tracker.pressure == .swapping)
    }

    @Test func anEmptyTrackerReadsNormal() {
        #expect(MemoryPressureTracker().pressure == .normal)
    }
}
