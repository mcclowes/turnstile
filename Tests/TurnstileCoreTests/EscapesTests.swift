import Foundation
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

    @Test("Doctor says how long it was watching, rather than implying it saw everything", .bug(id: 30))
    func describesTheWindowItWatched() {
        #expect(Escapes.watched(uptime: 0) == "the daemon didn't run in the last day")
        #expect(Escapes.watched(uptime: 3 * 3600 + 720) == "the daemon was up 3h12m of the last day")
        #expect(Escapes.watched(uptime: 86400 - 60) == "the daemon was up all of the last day")
    }

    @Test("Uptime is the part of each daemon run inside the window", .bug(id: 30))
    func sumsUptimeInsideTheWindow() throws {
        let path = NSTemporaryDirectory() + "turnstile-runs-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Store(path: path)
        let early = store.startDaemonRun(at: 100)
        store.touchDaemonRun(early, at: 400)
        let late = store.startDaemonRun(at: 1000)
        store.touchDaemonRun(late, at: 1500)

        #expect(store.daemonUptime(since: 0, until: 2000) == 800)
        // Clipped at both ends of the window.
        #expect(store.daemonUptime(since: 300, until: 1200) == 300)
        #expect(store.daemonUptime(since: 1600, until: 2000) == 0)
    }
}
