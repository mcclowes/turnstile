import Foundation
import Testing

@testable import TurnstileCore

struct CustomToolClassifierTests {
    func classify(_ command: String, global: String, project: ConfigFile? = nil) throws -> Classification? {
        let words = command.split(separator: " ").map(String.init)
        let config = Config(global: try ConfigFile.decode(Data(global.utf8)), project: project)
        return Classifier.classify(
            tool: words[0], args: Array(words.dropFirst()), context: ClassifierContext(config: config))
    }

    @Test(arguments: [
        "godot --headless --path . -s tests/run_tests.gd", "godot --headless --editor --import",
        "npx godot --headless", "xcrun godot --headless",
    ])
    func customToolsUseTheCompileQueue(command: String) throws {
        let result = try classify(command, global: #"{"shims":{"add":["godot"]}}"#)
        #expect(result == Classification(.compile, key: "godot"))
    }

    @Test(arguments: ["--version", "-version", "-V", "--help", "-help", "-h"])
    func quickQueriesPassThrough(flag: String) throws {
        #expect(try classify("godot \(flag)", global: #"{"shims":{"add":["godot"]}}"#) == nil)
    }

    @Test(arguments: [
        "{}", #"{"shims":{"add":["bazel"]}}"#, #"{"shims":{"add":["godot"],"remove":["godot"]}}"#,
    ])
    func toolsWithoutAnEnabledCustomShimPassThrough(global: String) throws {
        #expect(try classify("godot --headless", global: global) == nil)
    }

    @Test func commandRulesOverrideTheCustomDefault() throws {
        let global = #"{"shims":{"add":["godot"]},"commands":{"godot":"pass"}}"#
        #expect(try classify("godot --headless", global: global) == nil)
        let project = ConfigFile(commands: ["godot --headless": .gate(.test, memory: Bytes.gb)])
        #expect(
            try classify("godot --headless", global: global, project: project)
                == Classification(.test, key: "godot", memory: Bytes.gb))
    }

    @Test func addingABuiltInToolPreservesItsClassification() throws {
        let global = #"{"shims":{"add":["swift"]}}"#
        #expect(try classify("swift test", global: global) == Classification(.test, key: "swift test"))
        #expect(try classify("swift package resolve", global: global) == nil)
    }
}
