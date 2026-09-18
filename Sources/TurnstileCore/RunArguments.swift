/// `turnstile run [--class <class>] [--] <command...>`. Options end at `--` or the first word that isn't one.
public struct RunArguments: Equatable, Sendable {
    public var forced: ResourceClass?
    public var command: [String]

    public init(forced: ResourceClass?, command: [String]) {
        self.forced = forced
        self.command = command
    }

    public enum Problem: Error, Equatable {
        case unknownClass(String)
        case noCommand
    }

    public static func parse(_ args: [String]) throws -> RunArguments {
        var forced: ResourceClass?
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" { index += 1; break }
            let value: String
            if arg == "--class", index + 1 < args.count {
                value = args[index + 1]
                index += 2
            } else if arg.hasPrefix("--class=") {
                value = String(arg.dropFirst("--class=".count))
                index += 1
            } else {
                break
            }
            guard let cls = ResourceClass(rawValue: value) else { throw Problem.unknownClass(value) }
            forced = cls
        }
        let command = Array(args[index...])
        guard !command.isEmpty else { throw Problem.noCommand }
        return RunArguments(forced: forced, command: command)
    }
}
