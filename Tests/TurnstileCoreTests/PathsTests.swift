import Foundation
import Testing
@testable import TurnstileCore

struct PathsTests {
    @Test func disablingWritesTheFlagAndEnablingRemovesIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("turnstile-paths-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let paths = Paths(home: home)
        #expect(!paths.isDisabled)
        #expect(paths.disabledSince == nil)

        try paths.setDisabled(true)
        #expect(paths.isDisabled)
        #expect(abs((paths.disabledSince ?? .distantPast).timeIntervalSinceNow) < 60)

        // Turning it off twice keeps the original time, so "off since" stays honest.
        let since = paths.disabledSince
        try paths.setDisabled(true)
        #expect(paths.disabledSince == since)

        try paths.setDisabled(false)
        #expect(!paths.isDisabled)
        try paths.setDisabled(false)
    }

    @Test func pausingTheQueueWritesItsOwnFlag() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("turnstile-paths-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let paths = Paths(home: home)
        #expect(!paths.isQueuePaused)

        try paths.setQueuePaused(true)
        #expect(paths.isQueuePaused)
        #expect(!paths.isDisabled)

        try paths.setQueuePaused(false)
        #expect(!paths.isQueuePaused)
        try paths.setQueuePaused(false)
    }

    @Test func eachModeLeavesExactlyItsOwnFlag() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("turnstile-paths-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let paths = Paths(home: home)
        #expect(paths.mode == .gated)

        try paths.setMode(.paused)
        #expect(paths.mode == .paused)
        #expect(paths.isQueuePaused && !paths.isDisabled)

        try paths.setMode(.ungated)
        #expect(paths.mode == .ungated)
        #expect(paths.isDisabled && !paths.isQueuePaused)

        try paths.setMode(.gated)
        #expect(paths.mode == .gated)
        #expect(!paths.isDisabled && !paths.isQueuePaused)
    }

    @Test func ungatedWinsWhenBothFlagsAreSet() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("turnstile-paths-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let paths = Paths(home: home)
        try paths.setDisabled(true)
        try paths.setQueuePaused(true)
        // The shims pass straight through before the daemon's pause could hold anything.
        #expect(paths.mode == .ungated)
    }
}
