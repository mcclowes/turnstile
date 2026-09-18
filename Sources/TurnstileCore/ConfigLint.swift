import Foundation

public enum ConfigScope: Sendable {
    case global, project
}

/// Problems the decoder lets through: typos, keys in the wrong file, and values that decode but make no sense.
/// Keys starting with "//" or "$" are comments and never warned about.
public enum ConfigLint {
    static let fileKeys = ConfigFile.CodingKeys.allCases.map(\.rawValue)
    static let machineKeys = MachineConfig.CodingKeys.allCases.map(\.rawValue)
    static let throttleKeys = ThrottleConfig.CodingKeys.allCases.map(\.rawValue)
    static let ruleKeys = ["class", "memory"]
    static let shimKeys = ["add", "remove"]

    public static func warnings(_ data: Data, scope: ConfigScope) -> [String] {
        guard !data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var warnings: [String] = []

        let allowed = fileKeys + machineKeys
        for key in root.keys.sorted() where !isComment(key) {
            if !allowed.contains(key) {
                warnings.append(unknown(key, among: allowed))
            } else if scope == .project && machineKeys.contains(key) {
                warnings.append("\"\(key)\" only applies in the global config; a project can't change machine limits")
            }
        }

        if let throttle = root["throttle"] as? [String: Any] {
            warnings += unknownKeys(throttle, among: throttleKeys, path: "throttle")
        }
        for section in ["commands", "scripts"] {
            for (name, rule) in (root[section] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                if let object = rule as? [String: Any] {
                    warnings += unknownKeys(object, among: ruleKeys, path: "\(section).\(name)")
                }
            }
        }
        if scope == .global {
            warnings += machine(root)
        }
        return warnings
    }

    static func machine(_ root: [String: Any]) -> [String] {
        var warnings: [String] = []
        let classes = ResourceClass.allCases.map(\.rawValue)
        for (name, value) in (root["concurrency"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) where !isComment(name) {
            if !classes.contains(name) {
                warnings.append("unknown class \"concurrency.\(name)\" (use compile, test, or browser)")
            } else if let limit = value as? Int, limit < 1 {
                warnings.append("\"concurrency.\(name)\" must be at least 1")
            }
        }
        if let shims = root["shims"] as? [String: Any] {
            warnings += unknownKeys(shims, among: shimKeys, path: "shims")
        }
        let pause = root["pauseBelow"] as? Int
        let resume = root["resumeAbove"] as? Int
        for (key, value) in [("pauseBelow", pause), ("resumeAbove", resume)] {
            if let value, !(0...100).contains(value) { warnings.append("\"\(key)\" is a percentage, 0 to 100") }
        }
        let effectivePause = pause ?? MachineConfig().pauseBelowPercent
        let effectiveResume = resume ?? MachineConfig().resumeAbovePercent
        if (pause != nil || resume != nil), effectivePause >= effectiveResume, (0...100).contains(effectivePause) {
            warnings.append("\"pauseBelow\" (\(effectivePause)) should be lower than \"resumeAbove\" (\(effectiveResume))")
        }
        return warnings
    }

    static func unknownKeys(_ object: [String: Any], among allowed: [String], path: String) -> [String] {
        object.keys.sorted().filter { !isComment($0) && !allowed.contains($0) }.map { unknown($0, among: allowed, path: path) }
    }

    static func unknown(_ key: String, among allowed: [String], path: String? = nil) -> String {
        let full = path.map { "\($0).\(key)" } ?? key
        guard let guess = closest(key, among: allowed) else { return "unknown key \"\(full)\"" }
        return "unknown key \"\(full)\" (did you mean \"\(guess)\"?)"
    }

    static func isComment(_ key: String) -> Bool { key.hasPrefix("//") || key.hasPrefix("$") }

    /// Nearest allowed key within a small edit distance, compared case-insensitively.
    static func closest(_ key: String, among allowed: [String]) -> String? {
        let scored = allowed.map { ($0, distance(key.lowercased(), $0.lowercased())) }
        guard let best = scored.min(by: { $0.1 < $1.1 }) else { return nil }
        return best.1 <= max(2, key.count / 3) ? best.0 : nil
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return a.isEmpty ? b.count : previous[b.count]
    }
}
