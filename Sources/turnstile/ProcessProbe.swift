import Darwin
import TurnstileCore

/// What the escape scan needs to know about other processes. Indirect so tests can hand the daemon a process table.
struct ProcessProbe {
    var table: () -> [pid_t: ProcessTree.Entry]
    var executable: (pid_t) -> String?
    var arguments: (pid_t) -> [String]?
    var workingDirectory: (pid_t) -> String?
    var lineage: (pid_t) -> ProcessTree.Lineage?

    static let live = ProcessProbe(
        table: ProcessTree.table,
        executable: ProcessTree.executable,
        arguments: ProcessTree.arguments,
        workingDirectory: ProcessTree.workingDirectory,
        lineage: ProcessTree.lineage
    )
}
