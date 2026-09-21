import AppKit
import TurnstileCore

/// Reading a run's captured output. The app hands off to the log viewer and `turnstile logs -f` rather than tailing itself.
enum RunLogActions {
    static func open(_ log: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: log))
    }

    /// Opens a `.command` file, so it runs in the user's terminal without asking to automate Terminal.
    static func follow(job id: Int64, paths: Paths = Paths()) {
        let script = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("turnstile-follow-\(id).command")
        do {
            try RunLogs.followScript(executable: paths.shims + "/turnstile", job: id).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            NSSound.beep()
        }
    }
}
