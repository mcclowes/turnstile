import CryptoKit
import Foundation

public struct Workspace: Equatable, Sendable {
    /// Worktree root, or the working directory outside git.
    public var root: String
    /// Hash of HEAD plus uncommitted changes. Nil outside git, so nothing merges.
    public var fingerprint: String?

    /// Identifies the working tree's contents: HEAD, the staged and unstaged diff, and untracked files' sizes and mtimes.
    public static func inspect(cwd: String, argv: [String]) -> Workspace {
        guard let top = git(["rev-parse", "--show-toplevel", "HEAD"], cwd: cwd) else {
            return Workspace(root: cwd, fingerprint: nil)
        }
        let lines = String(decoding: top, as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count == 2 else { return Workspace(root: lines.first ?? cwd, fingerprint: nil) }
        let root = lines[0]

        var hash = SHA256()
        hash.update(data: Data(lines[1].utf8))
        hash.update(data: Data(cwd.utf8))
        for arg in argv { hash.update(data: Data((arg + "\u{0}").utf8)) }
        guard let diff = git(["diff", "HEAD", "--no-color", "--no-ext-diff", "--binary"], cwd: root),
              let untracked = git(["ls-files", "--others", "--exclude-standard", "-z"], cwd: root) else {
            return Workspace(root: root, fingerprint: nil)
        }
        hash.update(data: diff)
        for path in untracked.split(separator: 0).map({ String(decoding: $0, as: UTF8.self) }) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: root + "/" + path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            hash.update(data: Data("\(path)\u{0}\(size)\u{0}\(mtime)\u{0}".utf8))
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return Workspace(root: root, fingerprint: digest)
    }

    static func git(_ args: [String], cwd: String) -> Data? {
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
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
