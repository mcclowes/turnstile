import CryptoKit
import Foundation

public struct Workspace: Equatable, Sendable {
    /// Worktree root, or the working directory outside git.
    public var root: String
    /// Hash of HEAD plus each changed or untracked path's object ids, size, and mtime. Nil outside git, so nothing merges.
    public var fingerprint: String?

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
        guard let root = toplevel(from: cwd) else { return Workspace(root: cwd, fingerprint: nil) }
        let deadline = Date(timeIntervalSinceNow: budget)
        guard let porcelain = git(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--no-renames"], cwd: root, deadline: deadline) else {
            return Workspace(root: root, fingerprint: nil)
        }
        let status = Status(porcelain: porcelain)
        guard let head = status.head else { return Workspace(root: root, fingerprint: nil) }

        var hash = SHA256()
        hash.update(data: Data(head.utf8))
        hash.update(data: Data(cwd.utf8))
        for arg in argv { hash.update(data: Data((arg + "\u{0}").utf8)) }
        for input in environmentInputs(environment) { hash.update(data: Data((input + "\u{0}").utf8)) }
        // Changed paths are identified like untracked ones always were: git's object ids plus size and mtime,
        // so the cost follows the number of changed files, not the size of their diff.
        for entry in status.entries {
            hash.update(data: Data((entry.record + "\u{0}" + fileStamp(root + "/" + entry.path) + "\u{0}").utf8))
        }
        // Ignored .env files change test results without showing up in git.
        let envFiles = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasPrefix(".env") }.sorted()
        for name in envFiles {
            hash.update(data: Data("\(name)\u{0}\(fileStamp(root + "/" + name))\u{0}".utf8))
        }
        guard Date() < deadline else { return Workspace(root: root, fingerprint: nil) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return Workspace(root: root, fingerprint: digest)
    }

    /// The worktree root, as `git rev-parse --show-toplevel` would print it, without starting git.
    static func toplevel(from cwd: String) -> String? {
        guard let resolved = realpath(cwd, nil) else { return nil }
        var directory = String(cString: resolved)
        free(resolved)
        while true {
            if FileManager.default.fileExists(atPath: directory + "/.git") { return directory }
            if directory == "/" { return nil }
            directory = (directory as NSString).deletingLastPathComponent
        }
    }

    /// Size, mtime, and inode, or a marker for a missing file.
    static func fileStamp(_ path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "-" }
        return "\(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_ino)"
    }

    /// `git status --porcelain=v2 -z --branch` output.
    struct Status {
        struct Entry: Equatable {
            /// The whole record: change type, modes, object ids, and path(s).
            var record: String
            var path: String
        }

        var head: String?
        var entries: [Entry] = []

        init(porcelain: Data) {
            var fields = porcelain.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }[...]
            while let field = fields.popFirst() {
                if field.hasPrefix("# branch.oid ") {
                    head = String(field.dropFirst("# branch.oid ".count))
                    continue
                }
                // Fields before the path: `1` has 8, `2` has 9 (plus the original path as the next field), `u` has 10.
                let (skip, record): (Int, String)
                switch field.first {
                case "1": (skip, record) = (8, field)
                case "2": (skip, record) = (9, field + "\u{0}" + (fields.popFirst() ?? ""))
                case "u": (skip, record) = (10, field)
                case "?": (skip, record) = (1, field)
                default: continue
                }
                let path = field.split(separator: " ", maxSplits: skip, omittingEmptySubsequences: false).dropFirst(skip).first.map(String.init)
                if let path { entries.append(Entry(record: record, path: path)) }
            }
        }
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
