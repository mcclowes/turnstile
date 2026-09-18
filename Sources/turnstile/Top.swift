import Darwin
import Foundation
import TurnstileCore

/// Terminal settings to put back, for the signal handlers, which can't capture context.
nonisolated(unsafe) private var savedTermios = termios()
nonisolated(unsafe) private var termiosSaved = false

private let enterScreen = "\u{1B}[?1049h\u{1B}[?25l"
private let leaveScreen = "\u{1B}[?25h\u{1B}[?1049l"

/// `turnstile top`: an interactive view of the queue.
enum Top {
    static func main(_ args: [String]) -> Never {
        guard isatty(0) == 1, isatty(1) == 1 else {
            warn("top needs a terminal; use `turnstile status --watch` or `status --json` instead")
            exit(64)
        }
        let paths = Paths(environment: ProcessInfo.processInfo.environment)
        enterRawMode()
        installSignalHandlers()

        var snapshot: StatusSnapshot?
        var selected: Int64?
        var footer = ""
        var confirmingKill: JobSnapshot?
        var lastPoll = 0.0

        while true {
            let now = Date().timeIntervalSince1970
            if now - lastPoll >= 1 {
                snapshot = fetch(paths: paths)
                lastPoll = now
            }
            let rows = TopScreen.rows(snapshot)
            selected = TopScreen.settle(selected, in: rows)
            if let pending = confirmingKill, !rows.contains(where: { $0.id == pending.id }) {
                confirmingKill = nil
                footer = "#\(pending.id) finished before it was killed"
            }
            let prompt = confirmingKill.map { "kill #\($0.id) \($0.label)? y/n" } ?? footer
            draw(TopScreen.render(snapshot, selected: selected, now: now, width: size().width, height: size().height, footer: prompt))

            for key in readKeys(timeout: 1 - (Date().timeIntervalSince1970 - lastPoll)) {
                if let pending = confirmingKill {
                    confirmingKill = nil
                    footer = key == .yes ? send("kill", to: pending.id, paths: paths) : "kept #\(pending.id)"
                    lastPoll = 0
                    continue
                }
                switch key {
                case .quit: quit()
                case .up: selected = TopScreen.move(selected, by: -1, in: rows)
                case .down: selected = TopScreen.move(selected, by: 1, in: rows)
                case .bump, .pause, .hold, .kill:
                    guard let job = rows.first(where: { $0.id == selected }) else {
                        footer = "nothing selected"
                        continue
                    }
                    switch TopScreen.control(for: key, job: job) {
                    case .success("kill"): confirmingKill = job
                    case let .success(action):
                        footer = send(action, to: job.id, paths: paths)
                        lastPoll = 0
                    case let .failure(problem): footer = problem.text
                    }
                default:
                    break
                }
            }
        }
    }

    static func fetch(paths: Paths) -> StatusSnapshot? {
        guard let client = Client.connect(socketPath: paths.socket) else { return nil }
        return client.roundTrip(Message(type: "status"), timeout: 2)?.status
    }

    static func send(_ action: String, to id: Int64, paths: Paths) -> String {
        guard let client = Client.connect(socketPath: paths.socket) else { return "the daemon has stopped" }
        var message = Message(type: action)
        message.target = "\(id)"
        guard let reply = client.roundTrip(message) else { return "no reply from the daemon" }
        return reply.text ?? action
    }

    // MARK: Terminal

    static func size() -> (width: Int, height: Int) {
        var window = winsize()
        guard ioctl(1, TIOCGWINSZ, &window) == 0, window.ws_col > 0, window.ws_row > 0 else { return (80, 24) }
        return (Int(window.ws_col), Int(window.ws_row))
    }

    static func draw(_ lines: [String]) {
        let text = "\u{1B}[H" + lines.map { $0 + "\u{1B}[K" }.joined(separator: "\r\n") + "\u{1B}[J"
        FileHandle.standardOutput.write(text)
    }

    /// Keys typed within `timeout` seconds. Returns early, with none, on a resize.
    static func readKeys(timeout: Double) -> [TopScreen.Key] {
        var descriptor = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(max(0, timeout) * 1000)) > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(0, &buffer, buffer.count)
        if count == 0 { quit() }
        return count > 0 ? TopScreen.keys(Array(buffer.prefix(count))) : []
    }

    static func enterRawMode() {
        guard tcgetattr(0, &savedTermios) == 0 else { return }
        termiosSaved = true
        var raw = savedTermios
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        tcsetattr(0, TCSAFLUSH, &raw)
        FileHandle.standardOutput.write(enterScreen)
    }

    static func quit() -> Never {
        restoreTerminal()
        exit(0)
    }

    static func installSignalHandlers() {
        // A no-op handler, without SA_RESTART, so a resize interrupts poll(2) and the screen redraws at once.
        var resize = sigaction()
        resize.__sigaction_u.__sa_handler = { _ in }
        sigemptyset(&resize.sa_mask)
        resize.sa_flags = 0
        sigaction(SIGWINCH, &resize, nil)
        for sig in [SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig) { received in
                restoreTerminal()
                signal(received, SIG_DFL)
                kill(getpid(), received)
            }
        }
        atexit { restoreTerminal() }
    }
}

/// Async-signal-safe: only write(2) and tcsetattr(3).
private func restoreTerminal() {
    guard termiosSaved else { return }
    termiosSaved = false
    leaveScreen.withCString { _ = write(1, $0, strlen($0)) }
    tcsetattr(0, TCSAFLUSH, &savedTermios)
}
