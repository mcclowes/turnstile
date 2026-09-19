import Foundation

public enum Bytes {
    public static let mb: UInt64 = 1 << 20
    public static let gb: UInt64 = 1 << 30

    /// Parses "4GB", "512 MB", "2g", "1.5 GB". A bare number is megabytes.
    public static func parse(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits), value >= 0 else { return nil }
        let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let multiplier: Double
        switch unit {
        case "", "m", "mb", "mib": multiplier = Double(mb)
        case "g", "gb", "gib": multiplier = Double(gb)
        case "k", "kb", "kib": multiplier = 1024
        case "t", "tb", "tib": multiplier = Double(gb) * 1024
        default: return nil
        }
        return UInt64(value * multiplier)
    }

    /// "512 MB", "1.5 GB", "12 GB".
    public static func format(_ bytes: UInt64) -> String {
        if bytes < gb {
            return "\(max(1, Int((Double(bytes) / Double(mb)).rounded()))) MB"
        }
        let value = Double(bytes) / Double(gb)
        if value >= 10 { return "\(Int(value.rounded())) GB" }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? "\(Int(rounded)) GB"
            : String(format: "%.1f GB", rounded)
    }
}

public enum ResourceClass: String, Codable, CaseIterable, Sendable {
    case compile, test, browser

    public var defaultEstimate: UInt64 {
        switch self {
        case .compile: return 2 * Bytes.gb
        case .test: return 2 * Bytes.gb
        case .browser: return 3 * Bytes.gb
        }
    }

    /// `taskpolicy` flags for an agent's job. Background priority can starve a test run into timeouts,
    /// which an agent reads as real failures, so tests get the gentler utility clamp.
    public var agentPolicy: [String] {
        switch self {
        case .compile: return ["-b"]
        case .test, .browser: return ["-c", "utility"]
        }
    }
}

public func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m\(String(format: "%02d", s % 60))s" }
    return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))m"
}
