import CryptoKit
import Foundation

public struct Workspace: Equatable, Sendable {
    /// Worktree root, or the working directory outside git.
    public var root: String
    /// Hash of HEAD plus uncommitted changes. Nil outside git, so nothing merges.
    public var fingerprint: String?
    /// The main checkout's root when `root` is a linked worktree, so a new worktree can borrow its history.
    public var home: String? = nil

    /// Identifies the working tree's contents: HEAD, the staged and unstaged diff, and untracked files' sizes and mtimes.
    /// Variables that commonly change what a build or test does, so runs that differ in them never merge.
    public static func environmentInputs(_ environment: [String: String]) -> [String] {
        let exact: Set<String> = ["CI", "NODE_ENV", "RAILS_ENV", "RUST_BACKTRACE", "RUSTFLAGS", "CFLAGS", "GOFLAGS", "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "CONFIGURATION"]
        return environment.keys
            .filter { exact.contains($0) || $0.uppercased().contains("TEST") }
            .sorted()
            .map { "\($0)=\(environment[$0]!)" }
    }

    /// Seconds the fingerprint may take. A large diff (a changed binary, say) can take git several seconds,
    /// and a run that merges nothing is cheaper than every run waiting on git.
    public static let fingerprintBudget: TimeInterval = 1

    public static func inspect(cwd: String, argv: [String], environment: [String: String] = [:], budget: TimeInterval = fingerprintBudget) -> Workspace {
        guard let top = git(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "HEAD"], cwd: cwd, deadline: .distantFuture) else {
            return Workspace(root: cwd, fingerprint: nil)
        }
        let lines = String(decoding: top, as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count == 3 else { return Workspace(root: lines.first ?? cwd, fingerprint: nil) }
        let root = lines[0]
        let home = mainCheckout(commonDir: lines[1]).flatMap { $0 == root ? nil : $0 }

        var hash = SHA256()
        hash.update(data: Data(lines[2].utf8))
        hash.update(data: Data(cwd.utf8))
        for arg in argv { hash.update(data: Data((arg + "\u{0}").utf8)) }
        for input in environmentInputs(environment) { hash.update(data: Data((input + "\u{0}").utf8)) }
        let deadline = Date(timeIntervalSinceNow: budget)
        guard git(["diff", "HEAD", "--no-color", "--no-ext-diff", "--binary"], cwd: root, deadline: deadline, consume: { hash.update(data: $0) }),
              let untracked = git(["ls-files", "--others", "--exclude-standard", "-z"], cwd: root, deadline: deadline) else {
            return Workspace(root: root, fingerprint: nil, home: home)
        }
        // Ignored .env files change test results without showing up in git.
        let envFiles = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasPrefix(".env") }.sorted()
        for name in envFiles {
            let attributes = try? FileManager.default.attributesOfItem(atPath: root + "/" + name)
            let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            hash.update(data: Data("\(name)\u{0}\((attributes?[.size] as? NSNumber)?.int64Value ?? -1)\u{0}\(mtime)\u{0}".utf8))
        }
        for path in untracked.split(separator: 0).map({ String(decoding: $0, as: UTF8.self) }) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: root + "/" + path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            hash.update(data: Data("\(path)\u{0}\(size)\u{0}\(mtime)\u{0}".utf8))
        }
        guard Date() < deadline else { return Workspace(root: root, fingerprint: nil, home: home) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return Workspace(root: root, fingerprint: digest, home: home)
    }

    /// The checkout that owns a shared `.git` directory; nil for a bare repository, which has none.
    static func mainCheckout(commonDir: String) -> String? {
        let path = commonDir as NSString
        guard path.lastPathComponent == ".git" else { return nil }
        return path.deletingLastPathComponent
    }

    /// The worktree root that jobs from `cwd` are recorded under, without hashing the tree's contents.
    public static func root(of cwd: String) -> String {
        guard let top = git(["rev-parse", "--show-toplevel"], cwd: cwd, deadline: .distantFuture),
              let line = String(decoding: top, as: UTF8.self).split(separator: "\n").first else { return cwd }
        return String(line)
    }

    static func git(_ args: [String], cwd: String, deadline: Date) -> Data? {
        var data = Data()
        return git(args, cwd: cwd, deadline: deadline, consume: { data.append($0) }) ? data : nil
    }

    /// Streams git's output to `consume`, so a huge diff is never held in memory.
    /// Fails if git fails or is still going at `deadline`, when it's killed.
    static func git(_ args: [String], cwd: String, deadline: Date, consume: (Data) -> Void) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd] + args
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["TURNSTILE_DISABLE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: timeout)
        let reader = output.fileHandleForReading
        while case let chunk = reader.availableData, !chunk.isEmpty { consume(chunk) }
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationReason == .exit && process.terminationStatus == 0 && Date() < deadline
    }
}
