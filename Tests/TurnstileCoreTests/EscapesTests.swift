import Testing
@testable import TurnstileCore

struct EscapesTests {
    @Test(arguments: [
        ("/usr/bin/swift-frontend", ["-frontend", "-c"], "swift-frontend"),
        ("/opt/rust/bin/rustc", ["src/main.rs"], "rustc"),
        ("/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", ["-scheme", "App"], "xcodebuild"),
        ("/usr/bin/clang", ["-cc1", "-emit-obj", "a.c"], "clang"),
        ("/opt/homebrew/bin/node", ["/app/node_modules/.bin/vitest", "run"], "node vitest"),
        ("/opt/homebrew/bin/node", ["/app/node_modules/jest-cli/bin/jest.js"], "node jest"),
        ("/opt/homebrew/bin/node", ["/app/node_modules/typescript/bin/tsc", "-p", "."], "node tsc"),
        ("/usr/bin/java", ["-cp", "/g/lib/gradle-launcher.jar", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"], "gradle"),
        ("/usr/bin/python3", ["-m", "pytest", "tests"], "pytest"),
    ])
    func namesHeavyProcesses(executable: String, args: [String], label: String) {
        #expect(Escapes.label(executable: executable, args: args) == label)
    }

    @Test(arguments: [
        ("/bin/sleep", ["30"]),
        ("/usr/bin/clang", ["-v"]),
        ("/opt/homebrew/bin/node", ["/app/node_modules/typescript/lib/tsserver.js"]),
        ("/opt/homebrew/bin/node", ["/app/server.js"]),
        ("/usr/bin/java", ["-jar", "app.jar"]),
        ("/usr/bin/python3", ["manage.py", "runserver"]),
    ])
    func ignoresEverythingElse(executable: String, args: [String]) {
        #expect(Escapes.label(executable: executable, args: args) == nil)
    }

    @Test func namesWhatStartedIt() {
        #expect(Escapes.via(chain: ["swift-driver", "SWBBuildService", "Xcode", "launchd"]) == "Xcode")
        #expect(Escapes.via(chain: ["XCBBuildService", "Xcode"]) == "Xcode")
        #expect(Escapes.via(chain: ["node", "zsh", "login"]) == "zsh")
        #expect(Escapes.via(chain: ["swift-frontend", "swift-driver", "swift-build", "claude"]) == "claude")
        #expect(Escapes.via(chain: []) == "an unknown process")
    }

    @Test func reportsTheBusiestFirst() {
        let rows = [
            EscapeRow(label: "swift-frontend", via: "Xcode", cwd: "/Users/me/app", count: 14, lastSeen: 0),
            EscapeRow(label: "node vitest", via: "zsh", cwd: "/Users/me/web", count: 3, lastSeen: 0),
        ]
        #expect(Escapes.report(rows, home: "/Users/me")
            == "14 × swift-frontend under Xcode in ~/app, 3 × node vitest under zsh in ~/web")
        #expect(Escapes.report([], home: "/Users/me") == nil)
    }
}
