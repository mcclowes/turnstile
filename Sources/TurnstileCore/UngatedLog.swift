import Darwin
import Foundation

/// Runs a shim let through ungated because it couldn't use the daemon. Best effort: a sandbox may block the write too.
public enum UngatedLog {
    public struct Entry: Equatable, Sendable {
        public var time: Double
        public var cause: String
        public var cwd: String
        public var command: String

        public init(time: Double, cause: String, cwd: String, command: String) {
            self.time = time
            self.cause = cause
            self.cwd = cwd
            self.command = command
        }
    }

    /// Tab-separated: time, cause, cwd, command. Tabs and newlines inside fields become spaces.
    public static func line(_ entry: Entry) -> String {
        let fields = [String(Int(entry.time)), entry.cause, entry.cwd, entry.command].map {
            $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        return fields.joined(separator: "\t") + "\n"
    }

    public static func parse(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let time = Double(fields[0]) else { return nil }
            return Entry(time: time, cause: fields[1], cwd: fields[2], command: fields[3])
        }
    }

    /// Keeps one previous generation once the log passes `limit` bytes.
    public static func append(_ entry: Entry, to path: String, limit: UInt64 = 256 << 10) {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 ?? 0
        if size > limit { _ = rename(path, path + ".1") }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(line(entry).utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    public static func read(_ path: String) -> [Entry] {
        parse((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
    }

    public static func summary(_ entries: [Entry], since cutoff: Double) -> (count: Int, latest: Entry)? {
        let recent = entries.filter { $0.time >= cutoff }
        guard let latest = recent.max(by: { $0.time < $1.time }) else { return nil }
        return (recent.count, latest)
    }

    /// One line for `turnstile doctor`, or nil if nothing went ungated in the last day.
    public static func describe(_ entries: [Entry], now: Double, home: String) -> String? {
        guard let (count, latest) = summary(entries, since: now - 86400) else { return nil }
        let cwd = latest.cwd.hasPrefix(home + "/") ? "~" + latest.cwd.dropFirst(home.count) : latest.cwd
        return "\(count) run\(count == 1 ? "" : "s") went ungated in the last day; the latest, `\(latest.command)` in \(cwd) "
            + "\(formatDuration(now - latest.time)) ago, because \(latest.cause)"
    }
}
