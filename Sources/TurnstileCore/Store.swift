import Foundation
import SQLite3

/// Job history in SQLite. Live queue state is held by the daemon; this records each job's lifecycle
/// and the peaks used to estimate future runs.
public final class Store {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw StoreError(message: "can't open \(path)")
        }
        sqlite3_busy_timeout(db, 2000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS jobs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              state TEXT NOT NULL,
              class TEXT NOT NULL,
              key TEXT NOT NULL,
              root TEXT NOT NULL,
              cwd TEXT NOT NULL,
              argv TEXT NOT NULL,
              agent INTEGER NOT NULL,
              client_pid INTEGER,
              child_pid INTEGER,
              estimate INTEGER,
              peak INTEGER,
              exit_code INTEGER,
              signal INTEGER,
              outcome TEXT,
              joined_to INTEGER,
              queued_at REAL NOT NULL,
              started_at REAL,
              finished_at REAL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS jobs_cost ON jobs(key, root, finished_at)")
    }

    deinit { sqlite3_close(db) }

    public func insertJob(state: String, resourceClass: ResourceClass, key: String, root: String, cwd: String, argv: [String], agent: Bool, clientPid: Int32, estimate: UInt64, now: Double) -> Int64 {
        let argvJSON = String(data: (try? JSONEncoder().encode(argv)) ?? Data(), encoding: .utf8) ?? "[]"
        run("""
            INSERT INTO jobs (state, class, key, root, cwd, argv, agent, client_pid, estimate, queued_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [state, resourceClass.rawValue, key, root, cwd, argvJSON, agent ? 1 : 0, Int64(clientPid), Int64(clamping: estimate), now])
        return sqlite3_last_insert_rowid(db)
    }

    public func markStarted(_ id: Int64, childPid: Int32?, now: Double) {
        run("UPDATE jobs SET state = 'running', child_pid = ?, started_at = ? WHERE id = ?", [childPid.map { Int64($0) }, now, id])
    }

    public func markFinished(_ id: Int64, outcome: String, exitCode: Int32?, signal: Int32?, peak: UInt64?, now: Double) {
        run("""
            UPDATE jobs SET state = 'finished', outcome = ?, exit_code = ?, signal = ?, peak = ?, finished_at = ?
            WHERE id = ?
            """, [outcome, exitCode.map { Int64($0) }, signal.map { Int64($0) }, peak.map { Int64(clamping: $0) }, now, id])
    }

    public func markJoined(_ id: Int64, to primary: Int64, outcome: String, exitCode: Int32?, now: Double) {
        run("UPDATE jobs SET state = 'finished', outcome = ?, joined_to = ?, exit_code = ?, finished_at = ? WHERE id = ?",
            [outcome, primary, exitCode.map { Int64($0) }, now, id])
    }

    /// Jobs left open by a daemon that died.
    public func abandonOpenJobs(now: Double) {
        run("UPDATE jobs SET state = 'finished', outcome = 'lost', finished_at = ? WHERE state != 'finished'", [now])
    }

    /// Usual peak for a command: the highest of its last five completed runs in this project,
    /// falling back to the same command in any project.
    public func usualPeak(key: String, root: String) -> UInt64? {
        let recent = "SELECT peak FROM jobs WHERE key = ? %@ AND outcome IN ('ok', 'failed') AND peak > 0 ORDER BY finished_at DESC LIMIT 5"
        if let peak = scalar("SELECT MAX(peak) FROM (\(String(format: recent, "AND root = ?")))", [key, root]) {
            return UInt64(peak)
        }
        return scalar("SELECT MAX(peak) FROM (\(String(format: recent, "")))", [key]).map(UInt64.init)
    }

    public func recent(limit: Int) -> [HistoryEntry] {
        var result: [HistoryEntry] = []
        query("""
            SELECT id, root, key, outcome, exit_code, peak, started_at, finished_at FROM jobs
            WHERE state = 'finished' ORDER BY finished_at DESC LIMIT ?
            """, [Int64(limit)]) { row in
            let started = row.double(6)
            let finished = row.double(7) ?? 0
            result.append(HistoryEntry(
                id: row.int(0) ?? 0,
                project: projectName(row.text(1) ?? ""),
                key: row.text(2) ?? "",
                outcome: row.text(3) ?? "",
                exitCode: row.int(4).map { Int32(truncatingIfNeeded: $0) },
                peak: row.int(5).map { UInt64(max(0, $0)) },
                duration: started.map { finished - $0 },
                finishedAt: finished
            ))
        }
        return result
    }

    public func prune(olderThan cutoff: Double) {
        run("DELETE FROM jobs WHERE state = 'finished' AND finished_at < ?", [cutoff])
    }

    // MARK: SQLite plumbing

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func prepare(_ sql: String, _ bindings: [Any?]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let value as String: sqlite3_bind_text(statement, index, value, -1, Store.transient)
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Double: sqlite3_bind_double(statement, index, value)
            default: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ bindings: [Any?]) {
        guard let statement = prepare(sql, bindings) else { return }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func scalar(_ sql: String, _ bindings: [Any?]) -> Int64? {
        var value: Int64?
        query(sql, bindings) { value = $0.int(0) }
        return value
    }

    private func query(_ sql: String, _ bindings: [Any?], row: (Row) -> Void) {
        guard let statement = prepare(sql, bindings) else { return }
        while sqlite3_step(statement) == SQLITE_ROW { row(Row(statement: statement)) }
        sqlite3_finalize(statement)
    }

    private struct Row {
        let statement: OpaquePointer?

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func int(_ column: Int32) -> Int64? { isNull(column) ? nil : sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double? { isNull(column) ? nil : sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String? {
            guard !isNull(column), let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }
    }
}

public struct StoreError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

public func projectName(_ root: String) -> String {
    (root as NSString).lastPathComponent
}
