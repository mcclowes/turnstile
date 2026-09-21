import Foundation
import SQLite3

/// How close a job came to being paused for memory.
public struct JobMemory: Equatable, Sendable {
    /// Lowest `kern.memorystatus_level` seen while it ran.
    public var minLevel: Int?
    public var maxPressure: MemoryPressure?
    /// Seconds paused for memory or by a person.
    public var pausedFor: Double?
    /// The kernel's pressure verdict would have paused it, though the level threshold didn't.
    public var wouldPause: Bool

    public init(minLevel: Int? = nil, maxPressure: MemoryPressure? = nil, pausedFor: Double? = nil, wouldPause: Bool = false) {
        self.minLevel = minLevel
        self.maxPressure = maxPressure
        self.pausedFor = pausedFor
        self.wouldPause = wouldPause
    }
}

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
              finished_at REAL,
              ran_for REAL,
              min_level INTEGER,
              max_pressure INTEGER,
              paused_for REAL,
              would_pause INTEGER
            )
            """)
        var columns: Set<String> = []
        query("PRAGMA table_info(jobs)", []) { row in row.text(1).map { columns.insert($0) } }
        for (column, type) in [("ran_for", "REAL"), ("min_level", "INTEGER"), ("max_pressure", "INTEGER"), ("paused_for", "REAL"), ("would_pause", "INTEGER")]
        where !columns.contains(column) {
            try execute("ALTER TABLE jobs ADD COLUMN \(column) \(type)")
        }
        try execute("CREATE INDEX IF NOT EXISTS jobs_cost ON jobs(key, root, finished_at)")
        try execute("""
            CREATE TABLE IF NOT EXISTS escapes (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              seen_at REAL NOT NULL,
              label TEXT NOT NULL,
              via TEXT NOT NULL,
              cwd TEXT NOT NULL,
              executable TEXT,
              chain TEXT
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS escapes_seen ON escapes(seen_at)")
    }

    deinit { sqlite3_close(db) }

    /// Opens the store, moving an unreadable database aside and starting fresh rather than failing.
    /// History only tunes estimates, so losing it is better than a daemon that can't start.
    public static func openOrReset(path: String, now: Double) throws -> (store: Store, setAside: String?) {
        if let store = try? Store(path: path), store.isHealthy { return (store, nil) }
        let aside = path + ".corrupt-\(Int(now))"
        try? FileManager.default.removeItem(atPath: aside)
        try FileManager.default.moveItem(atPath: path, toPath: aside)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        return (try Store(path: path), aside)
    }

    /// When a shim last registered a command. Opens read-only, so it never creates or migrates the database.
    public static func lastQueued(path: String) -> Double? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT MAX(queued_at) FROM jobs", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, 0)
    }

    var isHealthy: Bool {
        var ok = false
        query("PRAGMA quick_check", []) { ok = ok || $0.text(0) == "ok" }
        return ok
    }

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

    /// `ranFor` is seconds spent running, not counting time paused.
    public func markFinished(_ id: Int64, outcome: String, exitCode: Int32?, signal: Int32?, peak: UInt64?, ranFor: Double? = nil, memory: JobMemory = JobMemory(), now: Double) {
        run("""
            UPDATE jobs SET state = 'finished', outcome = ?, exit_code = ?, signal = ?, peak = ?, ran_for = ?,
              min_level = ?, max_pressure = ?, paused_for = ?, would_pause = ?, finished_at = ?
            WHERE id = ?
            """, [outcome, exitCode.map { Int64($0) }, signal.map { Int64($0) }, peak.map { Int64(clamping: $0) }, ranFor,
                  memory.minLevel.map { Int64($0) }, memory.maxPressure.map { Int64($0.rawValue) }, memory.pausedFor, memory.wouldPause ? Int64(1) : nil, now, id])
    }

    public func memory(of id: Int64) -> JobMemory? {
        var result: JobMemory?
        query("SELECT min_level, max_pressure, paused_for, would_pause FROM jobs WHERE id = ?", [id]) { row in
            result = JobMemory(
                minLevel: row.int(0).map(Int.init), maxPressure: row.int(1).map { MemoryPressure(level: $0) },
                pausedFor: row.double(2), wouldPause: row.int(3) == 1
            )
        }
        return result
    }

    public func markJoined(_ id: Int64, to primary: Int64, outcome: String, exitCode: Int32?, now: Double) {
        run("UPDATE jobs SET state = 'finished', outcome = ?, joined_to = ?, exit_code = ?, finished_at = ? WHERE id = ?",
            [outcome, primary, exitCode.map { Int64($0) }, now, id])
    }

    /// Jobs left open by a daemon that died.
    public func abandonOpenJobs(now: Double) {
        run("UPDATE jobs SET state = 'finished', outcome = 'lost', finished_at = ? WHERE state != 'finished'", [now])
    }

    /// What admission and the runaway ceiling are built from: the highest peak among this command's last
    /// twenty runs in this project, ignoring anything older than a month. Peaks are bimodal — a cold compile
    /// dwarfs an incremental one — and a short window forgets every cold run, admitting two 2 GB builds at 45 MB each.
    public func highWaterPeak(key: String, root: String, now: Double) -> UInt64? {
        scalar("""
            SELECT MAX(peak) FROM (SELECT peak FROM jobs WHERE key = ? AND root = ? AND outcome IN ('ok', 'failed')
            AND peak > 0 AND finished_at >= ? ORDER BY finished_at DESC LIMIT 20)
            """, [key, root, now - 30 * 86400]).map(UInt64.init)
    }

    /// A first guess for a command new to a project: the median of its last ten runs in other projects.
    /// Not the max, since one big project would otherwise hold that much memory for every first run.
    public func typicalPeak(key: String, excluding root: String) -> UInt64? {
        var peaks: [UInt64] = []
        query("""
            SELECT peak FROM jobs WHERE key = ? AND root != ? AND outcome IN ('ok', 'failed') AND peak > 0
            ORDER BY finished_at DESC LIMIT 10
            """, [key, root]) { row in row.int(0).map { peaks.append(UInt64($0)) } }
        guard !peaks.isEmpty else { return nil }
        peaks.sort()
        let middle = peaks.count / 2
        return peaks.count % 2 == 1 ? peaks[middle] : peaks[middle - 1] / 2 + peaks[middle] / 2
    }

    /// Usual run time for a command: the median of its last five successful runs in this project.
    /// Failed runs often stop early, so they'd make it look quicker than it is.
    public func usualDuration(key: String, root: String) -> Double? {
        var times: [Double] = []
        query("""
            SELECT ran_for FROM jobs WHERE key = ? AND root = ? AND outcome = 'ok' AND ran_for > 0
            ORDER BY finished_at DESC LIMIT 5
            """, [key, root]) { row in row.double(0).map { times.append($0) } }
        guard !times.isEmpty else { return nil }
        times.sort()
        let middle = times.count / 2
        return times.count % 2 == 1 ? times[middle] : (times[middle - 1] + times[middle]) / 2
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

    /// How a finished job ended, or nil while it runs or once it's pruned.
    public func outcome(of id: Int64) -> String? {
        var outcome: String?
        query("SELECT outcome FROM jobs WHERE id = ? AND state = 'finished'", [id]) { row in outcome = row.text(0) }
        return outcome
    }

    /// Every finished job since `cutoff`, for the history summary, optionally narrowed to one project.
    /// `ran_for` excludes time paused, and is missing from jobs a restarted daemon adopted, so those
    /// fall back to wall-clock time.
    public func history(since cutoff: Double, root: String?) -> [HistoryRow] {
        var rows: [HistoryRow] = []
        var bindings: [Any?] = [cutoff]
        if let root { bindings.append(root) }
        query("""
            SELECT root, key, agent, outcome, peak, COALESCE(ran_for, finished_at - started_at),
                   started_at - queued_at, finished_at
            FROM jobs WHERE state = 'finished' AND finished_at >= ?\(root == nil ? "" : " AND root = ?")
            """, bindings) { row in
            rows.append(HistoryRow(
                root: row.text(0) ?? "",
                key: row.text(1) ?? "",
                agent: (row.int(2) ?? 0) != 0,
                outcome: row.text(3) ?? "",
                peak: row.int(4).map { UInt64(max(0, $0)) },
                duration: row.double(5),
                wait: row.double(6),
                finishedAt: row.double(7) ?? 0
            ))
        }
        return rows
    }

    public func prune(olderThan cutoff: Double) {
        run("DELETE FROM jobs WHERE state = 'finished' AND finished_at < ?", [cutoff])
        run("DELETE FROM escapes WHERE seen_at < ?", [cutoff])
    }

    // MARK: Runs that went around the shims

    public func insertEscape(label: String, via: String, cwd: String, executable: String, chain: [String], at: Double) {
        run("INSERT INTO escapes (seen_at, label, via, cwd, executable, chain) VALUES (?, ?, ?, ?, ?, ?)",
            [at, label, via, cwd, executable, chain.joined(separator: " < ")])
    }

    /// The same command from the same place, counted together, busiest first.
    public func escapes(since: Double, limit: Int = 5) -> [EscapeRow] {
        var rows: [EscapeRow] = []
        query("""
            SELECT label, via, cwd, COUNT(*), MAX(seen_at) FROM escapes WHERE seen_at >= ?
            GROUP BY label, via, cwd ORDER BY COUNT(*) DESC, MAX(seen_at) DESC LIMIT ?
            """, [since, Int64(limit)]) { row in
            rows.append(EscapeRow(
                label: row.text(0) ?? "?", via: row.text(1) ?? "?", cwd: row.text(2) ?? "?",
                count: Int(row.int(3) ?? 0), lastSeen: row.double(4) ?? 0
            ))
        }
        return rows
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
