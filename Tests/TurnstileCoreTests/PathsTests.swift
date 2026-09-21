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
}
