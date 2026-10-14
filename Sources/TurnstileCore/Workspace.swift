import CryptoKit
import Foundation

public struct Workspace: Equatable, Sendable {
    /// Worktree root, or the working directory outside git.
    public var root: String
    /// Hash of HEAD, index state, and changed files' metadata. Nil when inspection fails, so nothing merges.
    public var fingerprint: String?
    /// The main checkout's root when `root` is a linked worktree, so a new worktree can borrow its history.
    public var home: String? = nil

    /// Variables that commonly change what a build or test does, so runs that differ in them never merge.
    public static func environmentInputs(_ environment: [String: String]) -> [String] {
        let exact: Set<String> = [
            "CI", "NODE_ENV", "RAILS_ENV", "RUST_BACKTRACE", "RUSTFLAGS", "CFLAGS", "GOFLAGS",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS", "CONFIGURATION",
        ]
        return environment.keys
            .filter { exact.contains($0) || $0.uppercased().contains("TEST") }
            .sorted()
            .map { "\($0)=\(environment[$0]!)" }
    }

    /// Seconds allowed for status and file metadata; expiry disables merging for that run.
    public static let fingerprintBudget: TimeInterval = 1

    public static func inspect(
        cwd: String, argv: [String], environment: [String: String] = [:], budget: TimeInterval = fingerprintBudget
    ) -> Workspace {
        guard
            let top = git(
                ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "HEAD"], cwd: cwd,
                deadline: .distantFuture)
        else {
            return Workspace(root: cwd, fingerprint: nil)
        }
        let lines = String(decoding: top, as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count == 3 else { return Workspace(root: lines.first ?? cwd, fingerprint: nil) }
        let root = lines[0]
        let home = mainCheckout(commonDir: lines[1]).flatMap { $0 == root ? nil : $0 }
        let deadline = Date(timeIntervalSinceNow: budget)
        guard
            let porcelain = git(
                ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--no-renames"],
                cwd: root, deadline: deadline)
        else { return Workspace(root: root, fingerprint: nil, home: home) }
        let status = Status(porcelain: porcelain)
        guard let head = status.head else { return Workspace(root: root, fingerprint: nil, home: home) }

        var hash = SHA256()
        hash.update(data: Data(head.utf8))
        hash.update(data: Data(cwd.utf8))
        for arg in argv { hash.update(data: Data((arg + "\u{0}").utf8)) }
        for input in environmentInputs(environment) { hash.update(data: Data((input + "\u{0}").utf8)) }
        for entry in status.entries {
            guard Date() < deadline else { return Workspace(root: root, fingerprint: nil, home: home) }
            hash.update(data: Data((entry.record + "\u{0}" + fileStamp(root + "/" + entry.path) + "\u{0}").utf8))
        }
        // Ignored .env files change test results without showing up in git.
        let envFiles = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter {
            $0.hasPrefix(".env")
        }.sorted()
        for name in envFiles {
            hash.update(data: Data("\(name)\u{0}\(fileStamp(root + "/" + name))\u{0}".utf8))
        }
        guard Date() < deadline else { return Workspace(root: root, fingerprint: nil, home: home) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return Workspace(root: root, fingerprint: digest, home: home)
    }

    static func fileStamp(_ path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "-" }
        return "\(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) "
            + "\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec) \(info.st_ino)"
    }

    struct Status {
        struct Entry: Equatable {
            var record: String
            var path: String
        }

        var head: String?
        var entries: [Entry] = []

        init(porcelain: Data) {
            guard String(data: porcelain, encoding: .utf8) != nil else { return }
            var fields = porcelain.split(separator: 0, omittingEmptySubsequences: true)
                .map { String(decoding: $0, as: UTF8.self) }[...]
            while let field = fields.popFirst() {
                if field.hasPrefix("# branch.oid ") {
                    head = String(field.dropFirst("# branch.oid ".count))
                    continue
                }
                // Porcelain v2 has 8, 9, or 10 fields before a tracked path; renames also have a second NUL field.
                let (skip, record): (Int, String)
                switch field.first {
                case "1": (skip, record) = (8, field)
                case "2": (skip, record) = (9, field + "\u{0}" + (fields.popFirst() ?? ""))
                case "u": (skip, record) = (10, field)
                case "?": (skip, record) = (1, field)
                default: continue
                }
                let path = field.split(separator: " ", maxSplits: skip, omittingEmptySubsequences: false)
                    .dropFirst(skip).first.map(String.init)
                if let path { entries.append(Entry(record: record, path: path)) }
            }
        }
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
            let line = String(decoding: top, as: UTF8.self).split(separator: "\n").first
        else { return cwd }
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
