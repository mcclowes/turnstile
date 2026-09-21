import Foundation

/// Output captured from runs that had no terminal, one file per job under `Paths.logs`.
public enum RunLogs {
    public static let retention: Double = 86400
    /// A run that failed overnight, or over a weekend, is the one you want to read when you're back.
    public static let failedRetention: Double = 7 * 86400
    static let failedOutcomes: Set<String> = ["failed", "signaled", "killed"]

    /// How long a job's log is kept after its last write, given how the job ended (nil if unknown).
    public static func retention(outcome: String?) -> Double {
        outcome.map(failedOutcomes.contains) == true ? failedRetention : retention
    }

    public static func job(fromFileName name: String) -> Int64? {
        guard name.hasSuffix(".log") else { return nil }
        return Int64(name.dropLast(4))
    }

    /// A job number as typed on the command line: `12` or `#12`.
    public static func job(fromTarget target: String) -> Int64? {
        let trimmed = target.hasPrefix("#") ? target.dropFirst() : Substring(target)
        guard let id = Int64(trimmed), id > 0 else { return nil }
        return id
    }

    /// A `.command` file's contents that follows a job's output in whichever terminal opens it.
    public static func followScript(executable: String, job id: Int64) -> String {
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return "#!/bin/sh\nexec \(quoted) logs \(id) -f\n"
    }
}

extension Paths {
    public func log(forJob id: Int64) -> String { "\(logs)/\(id).log" }
}
