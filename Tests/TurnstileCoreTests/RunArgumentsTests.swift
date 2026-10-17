import Testing

@testable import TurnstileCore

struct RunArgumentsTests {
    @Test(arguments: [
        ["--help"], ["-h"], ["--class", "test", "--help"], ["--class=browser", "-h"],
    ])
    func recognizesHelpBeforeTheCommand(_ args: [String]) {
        #expect(throws: RunArguments.Problem.helpRequested) { try RunArguments.parse(args) }
    }

    @Test func classFlagOnlyConsumesItsOwnValue() throws {
        let parsed = try RunArguments.parse(["--class", "test", "--", "make", "test"])
        #expect(parsed == RunArguments(forced: .test, command: ["make", "test"]))
    }

    @Test func flagsAfterTheCommandBelongToIt() throws {
        #expect(
            try RunArguments.parse(["make", "--class", "x"])
                == RunArguments(forced: nil, command: ["make", "--class", "x"]))
        #expect(
            try RunArguments.parse(["--class=browser", "npx", "playwright"])
                == RunArguments(forced: .browser, command: ["npx", "playwright"]))
        #expect(
            try RunArguments.parse(["swift", "--class"])
                == RunArguments(forced: nil, command: ["swift", "--class"]))
        #expect(
            try RunArguments.parse(["--class=test", "swift", "--class"])
                == RunArguments(forced: .test, command: ["swift", "--class"]))
        #expect(
            try RunArguments.parse(["--", "--class"])
                == RunArguments(forced: nil, command: ["--class"]))
        #expect(
            try RunArguments.parse(["--", "--help"])
                == RunArguments(forced: nil, command: ["--help"]))
        #expect(
            try RunArguments.parse(["swift", "--help"])
                == RunArguments(forced: nil, command: ["swift", "--help"]))
        #expect(
            try RunArguments.parse(["--class=test", "swift", "-h"])
                == RunArguments(forced: .test, command: ["swift", "-h"]))
        #expect(
            try RunArguments.parse(["help"])
                == RunArguments(forced: nil, command: ["help"]))
    }

    @Test func rejectsBadInput() {
        #expect(throws: RunArguments.Problem.unknownClass("fast")) {
            try RunArguments.parse(["--class", "fast", "--", "make"])
        }
        #expect(throws: RunArguments.Problem.unknownClass("--help")) {
            try RunArguments.parse(["--class", "--help"])
        }
        #expect(throws: RunArguments.Problem.noCommand) { try RunArguments.parse(["--class", "test", "--"]) }
    }

    @Test(arguments: [["--class"], ["--class=test", "--class"]])
    func missingClassValueIsAUsageError(_ args: [String]) {
        #expect(throws: RunArguments.Problem.noCommand) { try RunArguments.parse(args) }
    }
}
