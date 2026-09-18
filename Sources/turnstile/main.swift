import Foundation
import TurnstileCore

// Shims are symlinks to this binary; the name it was invoked as picks the tool.
let invokedAs = (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent }) ?? "turnstile"
let arguments = Array(CommandLine.arguments.dropFirst())

if invokedAs == "turnstile" {
    CLI.main(arguments)
} else {
    Supervisor.shim(tool: invokedAs, args: arguments)
}
