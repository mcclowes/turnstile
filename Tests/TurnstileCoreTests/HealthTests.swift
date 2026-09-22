import Foundation
import Testing
@testable import TurnstileCore

struct HealthTests {
    let healthy = Health.Evidence(cliInstalled: true, shimsInstalled: true, configError: nil, lastGated: 100)

    func snapshot(version: String?) -> StatusSnapshot {
        StatusSnapshot(memoryLevel: 40, physicalMemory: 16 * Bytes.gb, reserve: 0, limits: [:], running: [], queued: [], recent: [], daemonPid: 1, version: version)
    }

    @Test func aHealthyInstallSaysNothing() {
        #expect(Health.findings(healthy, snapshot: nil).isEmpty)
        #expect(Health.findings(healthy, snapshot: snapshot(version: Turnstile.version)).isEmpty)
    }

    @Test func theAppAloneSaysNothingIsGatedAndHowToFixIt() {
        var evidence = healthy
        evidence.cliInstalled = false
        evidence.shimsInstalled = false
        evidence.lastGated = nil
        let findings = Health.findings(evidence, snapshot: nil)
        #expect(findings.count == 1)
        #expect(findings[0].tone == .danger)
        #expect(findings[0].text.contains("Nothing is gated"))
        #expect(findings[0].fix?.contains("turnstile init") == true)
    }

    @Test func gatingOffIsDanger() {
        var noShims = healthy
        noShims.shimsInstalled = false
        #expect(Health.findings(noShims, snapshot: nil).first?.fix == "turnstile shims")
        #expect(Health.findings(noShims, snapshot: nil).first?.tone == .danger)
    }

    @Test func weakerSignalsWarn() {
        var neverGated = healthy
        neverGated.lastGated = nil
        #expect(Health.findings(neverGated, snapshot: nil).map(\.tone) == [.warning])

        var badConfig = healthy
        badConfig.configError = "~/.config/turnstile/config.json"
        #expect(Health.findings(badConfig, snapshot: nil).first?.text.contains("~/.config/turnstile/config.json") == true)
        #expect(Health.findings(badConfig, snapshot: nil).first?.tone == .warning)
    }

    @Test func versionSkewSaysWhichSideIsBehind() {
        let older = Health.findings(healthy, snapshot: snapshot(version: "0.3.9"), appVersion: "0.4.0")
        #expect(older.count == 1)
        #expect(older[0].text.contains("0.3.9") && older[0].text.contains("0.4.0"))
        #expect(older[0].fix == "brew upgrade turnstile && turnstile restart")
        #expect(older[0].runnable)

        let newer = Health.findings(healthy, snapshot: snapshot(version: "0.10.0"), appVersion: "0.9.0")
        #expect(newer.first?.fix?.contains("turnstile-app") == true)

        // Daemons older than 0.2 don't report a version.
        #expect(Health.findings(healthy, snapshot: snapshot(version: nil), appVersion: "0.4.0").count == 1)
    }

    @Test func adviceIsNotRunnable() {
        var neverGated = healthy
        neverGated.lastGated = nil
        #expect(Health.findings(neverGated, snapshot: nil).first?.runnable == false)
    }

    @Test func terminalScriptRunsTheCommandInALoginShell() {
        let script = Health.terminalScript(for: "echo 'hi' && turnstile restart")
        #expect(script.hasPrefix("#!/bin/zsh -l\n"))
        #expect(script.contains("\necho 'hi' && turnstile restart\n"))
        #expect(script.contains(#"print -r -- '$ echo '\''hi'\'' && turnstile restart'"#))
    }

    @Test func dangerComesFirst() {
        var evidence = healthy
        evidence.configError = "~/.config/turnstile/config.json"
        evidence.shimsInstalled = false
        #expect(Health.findings(evidence, snapshot: nil).map(\.tone) == [.danger, .warning])
    }

    @Test func brokenGatingOverridesTheIcon() {
        var noShims = healthy
        noShims.shimsInstalled = false
        let findings = Health.findings(noShims, snapshot: nil)
        let busy = snapshot(version: Turnstile.version)
        #expect(MenuBarState.indicator(busy, health: findings) == .init(symbol: Health.brokenSymbol, count: nil, tone: .danger))
        #expect(MenuBarState.indicator(nil, health: []) == MenuBarState.indicator(nil))

        var neverGated = healthy
        neverGated.lastGated = nil
        #expect(MenuBarState.indicator(nil, health: Health.findings(neverGated, snapshot: nil)).tone == .warning)
    }

    /// The disabled flag has its own icon; only a broken install, which the toggle can't fix, outranks it.
    @Test func gatingOffKeepsItsIconUnlessTheInstallIsBroken() {
        var neverGated = healthy
        neverGated.lastGated = nil
        let off = MenuBarState.indicator(nil, disabled: true)
        #expect(MenuBarState.indicator(nil, health: [], disabled: true) == off)
        #expect(MenuBarState.indicator(nil, health: Health.findings(neverGated, snapshot: nil), disabled: true) == off)

        var noShims = healthy
        noShims.shimsInstalled = false
        #expect(MenuBarState.indicator(nil, health: Health.findings(noShims, snapshot: nil), disabled: true).symbol == Health.brokenSymbol)
    }

    @Test func gathersEvidenceWithoutCreatingAnything() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("turnstile-health-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let paths = Paths(home: home)
        let environment = ["HOME": home, "TURNSTILE_CONFIG_DIR": home + "/config"]

        let empty = Health.gather(paths: paths, environment: environment)
        #expect(empty == .init(cliInstalled: false, shimsInstalled: false, configError: nil, lastGated: nil))
        #expect(!FileManager.default.fileExists(atPath: home))

        try paths.ensure()
        try FileManager.default.createDirectory(atPath: paths.bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.bin + "/turnstile", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(atPath: paths.shims + "/swift", withDestinationPath: paths.bin + "/turnstile")
        try FileManager.default.createDirectory(atPath: home + "/config", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: home + "/config/config.json", contents: Data("{ nope".utf8))
        let store = try Store(path: paths.database)
        _ = store.insertJob(state: "queued", resourceClass: .compile, key: "swift build", root: "/a", cwd: "/a", argv: ["swift", "build"], agent: true, clientPid: 1, estimate: 0, now: 42)

        let full = Health.gather(paths: paths, environment: environment)
        #expect(full.cliInstalled && full.shimsInstalled)
        #expect(full.configError == home + "/config/config.json")
        #expect(full.lastGated == 42)
    }

    @Test func aShimPointingElsewhereDoesNotCount() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("turnstile-health-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let paths = Paths(home: home)
        try paths.ensure()
        try FileManager.default.createDirectory(atPath: paths.bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.bin + "/turnstile", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(atPath: paths.shims + "/swift", withDestinationPath: "/usr/bin/true")
        #expect(!Health.gather(paths: paths, environment: ["HOME": home]).shimsInstalled)
    }
}
