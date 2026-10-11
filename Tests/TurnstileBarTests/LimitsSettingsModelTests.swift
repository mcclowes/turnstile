import Foundation
import Testing

@testable import TurnstileBar
@testable import TurnstileCore

@MainActor
struct LimitsSettingsModelTests {
    @Test(arguments: PausePolicy.allCases, [nil, true, false] as [Bool?])
    func pauseSelectionPersistsAndReloads(_ policy: PausePolicy, _ previous: Bool?) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "turnstile-limits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        var throttle: [String: Any] = ["jobs": 2]
        throttle["pause"] = previous
        try JSONSerialization.data(withJSONObject: ["reserve": "4GB", "throttle": throttle]).write(to: file)
        let environment = ["TURNSTILE_CONFIG_DIR": root.path]
        let model = LimitsSettingsModel(environment: environment)

        model.setPause(policy)

        try #require(model.message == nil)
        #expect(model.settings.pause == policy)
        #expect(LimitsSettingsModel(environment: environment).settings.pause == policy)
        let saved = try ConfigFile.decode(Data(contentsOf: file))
        #expect(saved.throttle?.jobs == 2)
        #expect(saved.machine.reserve == 4 * Bytes.gb)

        model.restoreDefaults()

        try #require(model.message == nil)
        #expect(model.settings.pause == .compileOnly)
        #expect(try ConfigFile.decode(Data(contentsOf: file)).throttle?.pause == nil)
    }
}
