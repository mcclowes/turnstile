import Foundation

/// Adds the shims directory to PATH in shell startup files.
///
/// The block moves the shims directory to the front of PATH rather than just prepending, so it's
/// safe to source repeatedly. It goes in files that run late: macOS's `path_helper` (in
/// `/etc/zprofile`) and tools like nvm or mise reorder PATH, and the shims must end up first.
/// zsh and bash also repeat the move before each prompt, since `nvm use` and `mise activate`
/// reorder PATH after startup. The hook goes last, so it runs after mise's.
public enum ShellSetup {
    public static let begin = "# >>> turnstile >>>"
    public static let end = "# <<< turnstile <<<"

    public enum Shell: String, CaseIterable, Sendable {
        case zsh, bash, fish

        public static func detect(_ environment: [String: String]) -> Shell {
            let name = ((environment["SHELL"] ?? "zsh") as NSString).lastPathComponent
            return Shell(rawValue: name) ?? .zsh
        }

        /// zsh: .zshenv covers `zsh -c`, .zshrc and .zlogin run after path_helper and version managers.
        public var startupFiles: [String] {
            switch self {
            case .zsh: return [".zshenv", ".zshrc", ".zlogin"]
            case .bash: return [".bashrc", ".bash_profile"]
            case .fish: return [".config/fish/conf.d/turnstile.fish"]
            }
        }
    }

    public static func snippet(shell: Shell, shimsDir: String) -> String {
        let quoted = shimsDir.replacingOccurrences(of: "\"", with: "\\\"")
        switch shell {
        case .zsh:
            return """
                \(begin)
                _turnstile_shims_first() { path=("\(quoted)" ${path:#"\(quoted)"}); }
                _turnstile_shims_first
                export PATH
                typeset -ag precmd_functions chpwd_functions
                precmd_functions=(${precmd_functions:#_turnstile_shims_first} _turnstile_shims_first)
                chpwd_functions=(${chpwd_functions:#_turnstile_shims_first} _turnstile_shims_first)
                \(end)
                """
        case .bash:
            return """
                \(begin)
                _turnstile_shims_first() {
                  local shims="\(quoted)"
                  PATH=":$PATH:"; PATH="${PATH//":$shims:"/:}"; PATH="${PATH#:}"; PATH="${PATH%:}"
                  PATH="$shims${PATH:+:$PATH}"
                }
                _turnstile_shims_first
                export PATH
                case "${PROMPT_COMMAND:-}" in
                  *_turnstile_shims_first*) ;;
                  *) PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}_turnstile_shims_first" ;;
                esac
                \(end)
                """
        case .fish:
            return """
                \(begin)
                fish_add_path --global --move --path "\(quoted)"
                \(end)
                """
        }
    }

    /// Returns `contents` with the managed block replaced, or appended if missing.
    public static func install(_ snippet: String, into contents: String) -> String {
        let stripped = remove(from: contents)
        var result = stripped
        if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
        if !result.isEmpty && !result.hasSuffix("\n\n") { result += "\n" }
        return result + snippet + "\n"
    }

    public static func remove(from contents: String) -> String {
        var lines = contents.components(separatedBy: "\n")
        while let start = lines.firstIndex(of: begin) {
            guard let stop = lines[start...].firstIndex(of: end) else { break }
            lines.removeSubrange(start...stop)
            if start > 0, start < lines.count, lines[start - 1].isEmpty, lines[start].isEmpty {
                lines.remove(at: start)
            }
        }
        var result = lines.joined(separator: "\n")
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result
    }
}
