import Foundation
import Testing
@testable import TurnstileCore

struct ConfigLintTests {
    func lint(_ json: String, _ scope: ConfigScope = .global) -> [String] {
        ConfigLint.warnings(Data(json.utf8), scope: scope)
    }

    @Test func validFilesHaveNoWarnings() {
        #expect(lint(#"{"concurrency": {"test": 2}, "reserve": "4GB", "throttle": {"jobs": 2}, "commands": {"make docs": "pass"}}"#).isEmpty)
        #expect(lint(#"{"scripts": {"e2e": {"class": "browser", "memory": "3GB"}}, "throttle": {"pause": false}}"#, .project).isEmpty)
        #expect(lint("").isEmpty)
    }

    @Test func suggestsTheKeyATypoMeant() {
        #expect(lint(#"{"concurency": {"test": 2}}"#) == [#"unknown key "concurency" (did you mean "concurrency"?)"#])
        #expect(lint(#"{"throttle": {"maxMemroy": "8GB"}}"#) == [#"unknown key "throttle.maxMemroy" (did you mean "maxMemory"?)"#])
        #expect(lint(#"{"banana": 1}"#) == [#"unknown key "banana""#])
    }

    @Test func machineKeysInAProjectAreIgnoredAndSaySo() {
        #expect(lint(#"{"concurrency": {"test": 2}}"#, .project) == [
            #""concurrency" only applies in the global config; a project can't change machine limits"#,
        ])
    }

    @Test func checksNestedValues() {
        #expect(lint(#"{"concurrency": {"tests": 2}}"#) == [#"unknown class "concurrency.tests" (use compile, test, or browser)"#])
        #expect(lint(#"{"concurrency": {"test": 0}}"#) == [#""concurrency.test" must be at least 1"#])
        #expect(lint(#"{"shims": {"added": ["bazel"]}}"#) == [#"unknown key "shims.added" (did you mean "add"?)"#])
        #expect(lint(#"{"commands": {"swift test": {"clas": "test"}}}"#) == [#"unknown key "commands.swift test.clas" (did you mean "class"?)"#])
    }

    @Test func pressureThresholdsMustMakeSense() {
        #expect(lint(#"{"pauseBelow": 30, "resumeAbove": 20}"#) == [#""pauseBelow" (30) should be lower than "resumeAbove" (20)"#])
        #expect(lint(#"{"pauseBelow": 130}"#) == [#""pauseBelow" is a percentage, 0 to 100"#])
    }

    @Test func commentKeysAreAllowed() {
        #expect(lint(#"{"//": "notes", "$schema": "x", "throttle": {"// why": "flaky CI"}}"#).isEmpty)
    }
}

struct ConfigErrorTests {
    @Test func syntaxErrorsSayWhere() {
        do {
            _ = try ConfigFile.decode(Data("{\n \"reserve\": \"4GB\",\n \"x\": }".utf8))
            Issue.record("expected a syntax error")
        } catch {
            let text = ConfigError(path: "config.json", underlying: error).description
            #expect(text.hasPrefix("config.json: invalid JSON:"))
            #expect(text.contains("line 3"))
        }
    }

    @Test func badValuesNameTheirKey() {
        do {
            _ = try ConfigFile.decode(Data(#"{"throttle": {"maxMemory": "big"}}"#.utf8))
            Issue.record("expected a bad size")
        } catch {
            #expect(ConfigError(path: "c", underlying: error).description == #"c: throttle.maxMemory: bad size "big""#)
        }
    }
}
