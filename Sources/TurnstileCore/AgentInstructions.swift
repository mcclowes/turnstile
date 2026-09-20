import Foundation

/// A few lines for a project's AGENTS.md or CLAUDE.md. Shims only gate what PATH resolves, so the
/// cheapest fix for the rest is telling agents how to start builds.
public enum AgentInstructions {
    public static let snippet = """
        ## Builds and tests

        Run builds and tests through the tool's usual name, so they're scheduled against the rest of
        the machine: `npm test`, `swift build`, `cargo test`. Don't call them by absolute path
        (`/usr/bin/swift`) or through `./node_modules/.bin`, which skips the scheduler. For anything
        else heavy, use `turnstile run -- <command>`.

        A queued command prints why it's waiting; that's not a hang, so wait for it. A command that
        exits 125 with `cancelled by you, don't retry` was stopped on purpose.
        """
}
