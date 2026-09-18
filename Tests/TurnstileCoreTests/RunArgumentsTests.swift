import Testing
@testable import TurnstileCore

struct RunArgumentsTests {
    @Test func classFlagOnlyConsumesItsOwnValue() throws {
        let parsed = try RunArguments.parse(["--class", "test", "--", "make", "test"])
        #expect(parsed == RunArguments(forced: .test, command: ["make", "test"]))
    }

    @Test func flagsAfterTheCommandBelongToIt() throws {
        #expect(try RunArguments.parse(["make", "--class", "x"]) == RunArguments(forced: nil, command: ["make", "--class", "x"]))
        #expect(try RunArguments.parse(["--class=browser", "npx", "playwright"]) == RunArguments(forced: .browser, command: ["npx", "playwright"]))
    }

    @Test func rejectsBadInput() {
        #expect(throws: RunArguments.Problem.unknownClass("fast")) { try RunArguments.parse(["--class", "fast", "--", "make"]) }
        #expect(throws: RunArguments.Problem.noCommand) { try RunArguments.parse(["--class", "test", "--"]) }
    }
}
