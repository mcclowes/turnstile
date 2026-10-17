import Testing

@testable import TurnstileCore

struct RunArgumentsTests {
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
    }

    @Test func rejectsBadInput() {
        #expect(throws: RunArguments.Problem.unknownClass("fast")) {
            try RunArguments.parse(["--class", "fast", "--", "make"])
        }
        #expect(throws: RunArguments.Problem.noCommand) { try RunArguments.parse(["--class", "test", "--"]) }
    }

    @Test(arguments: [["--class"], ["--class=test", "--class"]])
    func missingClassValueIsAUsageError(_ args: [String]) {
        #expect(throws: RunArguments.Problem.noCommand) { try RunArguments.parse(args) }
    }
}
