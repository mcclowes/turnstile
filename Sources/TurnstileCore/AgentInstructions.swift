import Foundation

/// Guidance printed by `turnstile agents` for a project's AGENTS.md or CLAUDE.md.
public enum AgentInstructions {
    public static let snippet = """
        ## Builds and tests

        Let Turnstile own machine-wide admission. Submit finite heavy work through supported gated
        invocations: shimmed `npm test`, `swift build`, or `cargo test`, or an explicit wrapper:
        `turnstile run --class test -- node node_modules/vitest/vitest.mjs run`.
        Use `--class compile` for TSC and `--class browser` for Playwright. Absolute tool paths and
        `./node_modules/.bin` bypass shims; wrap them with `turnstile run -- <command>`.
        Don't wrap interactive tools, dev servers, or watch commands.

        Wait for visible queued or paused work. Don't retry it outside the gate, disable gating,
        or negotiate machine-wide heavy-work hold/release broadcasts through Saggar. Keep genuine
        code/worktree ownership coordination. Exit 125 with `cancelled by you, don't retry` means
        the job was stopped on purpose.

        Diagnose failed-open warnings or inaccessible admission with `turnstile doctor --shells`
        and `turnstile status --json` in the actual harness. Verify a queued/running job or completed
        history row; exit zero alone doesn't prove admission. Report the harness, socket path, and
        connection error. A wrapper can't grant socket access; don't bypass sandbox restrictions.

        Default scheduling permits concurrency (three jobs per class). Test/browser jobs aren't
        normally auto-paused, and SourceKit/IDE work can remain unmanaged. Admission doesn't promise
        an exclusive performance-test window. Use deterministic, bounded functional tests without
        weakening assertions. Benchmarks need deliberate methodology: record competing load,
        warmup, repetitions, and variance. Explicit machine-exclusive scheduling is a future product
        decision, not an agent-maintained lock.
        """
}
