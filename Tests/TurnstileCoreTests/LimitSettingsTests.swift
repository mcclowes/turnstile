import Foundation
import Testing

@testable import TurnstileCore

struct LimitSettingsTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func emptyConfigMeansDefaults() throws {
        let settings = LimitSettings(file: try ConfigFile.decode(Data()))

        #expect(settings == LimitSettings())
        #expect(settings.pause == .compileOnly)
        #expect(settings.inject)
        #expect(settings.reserveBytes == 2 * Bytes.gb)
        #expect(settings.slots(for: .browser) == 3)
        #expect(settings.slots(for: .compile) == 3)
        #expect(settings.slots(for: .test) == 3)
    }

    @Test func readsMachineAndThrottleValues() throws {
        let data = Data(
            #"{"concurrency":{"test":5},"reserve":"4GB","throttle":{"pause":false,"inject":false,"killMultiplier":5,"maxMemory":"8GB"}}"#
                .utf8)
        let settings = LimitSettings(file: try ConfigFile.decode(data))

        #expect(settings.concurrency == [.test: 5])
        #expect(settings.slots(for: .test) == 5)
        #expect(settings.reserve == 4 * Bytes.gb)
        #expect(settings.pause == .never)
        #expect(!settings.inject)
        #expect(settings.killMultiplier == 5)
        #expect(settings.maxMemory == 8 * Bytes.gb)
    }

    @Test func writesOnlyWhatChanged() throws {
        let original = Data(
            #"{"$schema":"config.schema.json","reserve":"2GB","concurrency":{"test":3,"gpu":1},"shims":{"add":["bazel"]},"throttle":{"nodeHeap":"4GB"}}"#
                .utf8)
        var settings = LimitSettings(file: try ConfigFile.decode(original))
        settings.concurrency[.compile] = 2
        settings.pause = .never

        let updated = try json(try settings.updatingConfig(original))

        #expect(updated["$schema"] as? String == "config.schema.json")
        #expect(updated["reserve"] as? String == "2GB")
        #expect((updated["shims"] as? [String: Any])?["add"] as? [String] == ["bazel"])
        #expect(updated["concurrency"] as? [String: Int] == ["compile": 2, "test": 3, "gpu": 1])
        let throttle = try #require(updated["throttle"] as? [String: Any])
        #expect(throttle["nodeHeap"] as? String == "4GB")
        #expect(throttle["pause"] as? Bool == false)
    }

    @Test func restoringDefaultsRemovesKeys() throws {
        let original = Data(
            #"{"concurrency":{"test":3},"reserve":"4GB","throttle":{"pause":false,"killMultiplier":5,"maxMemory":"8GB"}}"#
                .utf8)

        let updated = try json(try LimitSettings().updatingConfig(original))

        #expect(updated.isEmpty)
    }

    @Test(.bug("https://github.com/mcclowes/turnstile/issues/65"))
    func allowingAllAgentJobsIsStoredExplicitly() throws {
        var settings = LimitSettings()
        settings.pause = .all

        let data = try settings.updatingConfig(Data())

        #expect(try ConfigFile.decode(data).throttle?.pause == true)
    }

    @Test(arguments: PausePolicy.allCases, [nil, true, false] as [Bool?])
    func pauseChoicesRoundTripAndKeepOtherSettings(_ policy: PausePolicy, _ previous: Bool?) throws {
        var root: [String: Any] = [
            "reserve": "4GB", "concurrency": ["test": 5],
            "throttle": ["inject": false, "jobs": 2, "nodeHeap": "3GB"],
        ]
        var throttle = try #require(root["throttle"] as? [String: Any])
        throttle["pause"] = previous
        root["throttle"] = throttle
        let original = try JSONSerialization.data(withJSONObject: root)
        var settings = LimitSettings(file: try ConfigFile.decode(original))
        settings.pause = policy

        let updated = try settings.updatingConfig(original)
        let decoded = try ConfigFile.decode(updated)
        let expected: Bool?
        switch policy {
        case .compileOnly: expected = nil
        case .all: expected = true
        case .never: expected = false
        }
        #expect(decoded.throttle?.pause == expected)
        #expect(LimitSettings(file: decoded).pause == policy)
        #expect(decoded.throttle?.inject == false)
        #expect(decoded.throttle?.jobs == 2)
        #expect(decoded.throttle?.nodeHeap == 3 * Bytes.gb)
        #expect(decoded.machine.reserve == 4 * Bytes.gb)
        #expect(decoded.machine.concurrency?["test"] == 5)
        #expect((try json(updated)["throttle"] as? [String: Any])?["nodeHeap"] as? String == "3GB")
    }

    @Test func writesSizesAsReadableStrings() throws {
        var settings = LimitSettings()
        settings.reserve = 3 * Bytes.gb / 2
        settings.maxMemory = 12 * Bytes.gb

        let data = try settings.updatingConfig(Data())
        let updated = try json(data)

        #expect(updated["reserve"] as? String == "1.5 GB")
        #expect((updated["throttle"] as? [String: Any])?["maxMemory"] as? String == "12 GB")
        #expect(LimitSettings(file: try ConfigFile.decode(data)) == settings)
    }
}
