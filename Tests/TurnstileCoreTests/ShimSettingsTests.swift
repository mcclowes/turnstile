import Foundation
import Testing
@testable import TurnstileCore

struct ShimSettingsTests {
    @Test func reflectsBuiltInAndCustomShimConfiguration() throws {
        let machine = try ConfigFile.decode(Data(#"{"shims":{"add":["bazel"],"remove":["make"]}}"#.utf8)).machine
        let settings = ShimSettings(machine: machine)

        #expect(!settings.enabledDefaults.contains("make"))
        #expect(settings.enabledDefaults.contains("swift"))
        #expect(settings.custom == ["bazel"])
        #expect(settings.names.contains("bazel"))
        #expect(!settings.names.contains("make"))
    }

    @Test func updatesOnlyShimConfiguration() throws {
        let original = Data(#"{"$schema":"config.schema.json","//":"keep me","concurrency":{"test":3},"shims":{"add":["old"],"remove":["make"]}}"#.utf8)
        var settings = ShimSettings(machine: try ConfigFile.decode(original).machine)
        settings.enabledDefaults.remove("swift")
        settings.enabledDefaults.insert("make")
        settings.custom = ["bazel", "bazel"]

        let updated = try settings.updatingConfig(original)
        let json = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let shims = try #require(json["shims"] as? [String: Any])

        #expect(json["$schema"] as? String == "config.schema.json")
        #expect(json["//"] as? String == "keep me")
        #expect((json["concurrency"] as? [String: Int])?["test"] == 3)
        #expect(shims["add"] as? [String] == ["bazel"])
        #expect(shims["remove"] as? [String] == ["swift"])
    }
}
