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
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: timeout)
        let reader = output.fileHandleForReading
        while case let chunk = reader.availableData, !chunk.isEmpty { consume(chunk) }
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationReason == .exit, Date() < deadline else { return nil }
        return process.terminationStatus
    }
}
