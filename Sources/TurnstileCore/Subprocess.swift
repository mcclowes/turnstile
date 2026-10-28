import Foundation

enum Subprocess {
    /// Runs to completion, streaming stdout to `consume`, and kills the process if it's still going at `deadline`.
    /// The exit status, or nil if it couldn't start, died to a signal, or ran out of time.
    static func run(
        _ executable: String, _ arguments: [String], environment: [String: String], deadline: Date,
        consume: (Data) -> Void
    ) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // A thread of its own: a GCD timer can fire late when the shared pool is busy with blocking work.
        let watchdog = Thread {
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning { process.terminate() }
        }
        watchdog.start()
        let reader = output.fileHandleForReading
        while case let chunk = reader.availableData, !chunk.isEmpty { consume(chunk) }
        process.waitUntilExit()
        guard process.terminationReason == .exit, Date() < deadline else { return nil }
        return process.terminationStatus
    }
}
