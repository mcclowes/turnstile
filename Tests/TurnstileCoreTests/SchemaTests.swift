import Foundation
import Testing
@testable import TurnstileCore

/// The published schemas must list exactly the keys the decoder reads.
struct SchemaTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func schema(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: SchemaTests.root.appendingPathComponent("schema/\(name)"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func keys(_ object: [String: Any]?) -> Set<String> {
        Set((object?["properties"] as? [String: Any] ?? [:]).keys).subtracting(["$schema"])
    }

    @Test func globalSchemaMatchesTheDecoder() throws {
        let global = try schema("config.schema.json")
        #expect(keys(global) == Set(ConfigLint.fileKeys + ConfigLint.machineKeys))
    }

    @Test func projectSchemaLeavesOutMachineKeys() throws {
        let project = try schema("turnstilerc.schema.json")
        #expect(keys(project) == Set(ConfigLint.fileKeys))
    }

    @Test func nestedObjectsMatchTheDecoder() throws {
        for name in ["config.schema.json", "turnstilerc.schema.json"] {
            let definitions = try schema(name)["definitions"] as? [String: Any]
            #expect(keys(definitions?["throttle"] as? [String: Any]) == Set(ConfigLint.throttleKeys))
            let rule = (definitions?["rule"] as? [String: Any])?["oneOf"] as? [[String: Any]]
            #expect(keys(rule?.last) == Set(ConfigLint.ruleKeys))
        }
        let machine = try schema("config.schema.json")["properties"] as? [String: Any]
        #expect(keys(machine?["shims"] as? [String: Any]) == Set(ConfigLint.shimKeys))
        #expect(keys(machine?["concurrency"] as? [String: Any]) == Set(ResourceClass.allCases.map(\.rawValue)))
    }

    @Test func schemaKeyIsTreatedAsAComment() {
        let json = #"{"$schema": "https://example.com/config.schema.json", "throttle": {}}"#
        #expect(ConfigLint.warnings(Data(json.utf8), scope: .project).isEmpty)
        #expect((try? ConfigFile.decode(Data(json.utf8))) != nil)
    }
}
