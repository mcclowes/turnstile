import Foundation

public struct ShimSettings: Equatable, Sendable {
    public var enabledDefaults: Set<String>
    public var custom: [String]

    public init(machine: MachineConfig) {
        let removed = Set(machine.shims?.remove ?? [])
        enabledDefaults = Set(Classifier.defaultShims).subtracting(removed)
        custom = (machine.shims?.add ?? []).filter { !Classifier.defaultShims.contains($0) && !removed.contains($0) }
    }

    public var names: [String] {
        Classifier.defaultShims.filter(enabledDefaults.contains) + normalizedCustom
    }

    public func updatingConfig(_ data: Data) throws -> Data {
        let removed = Classifier.defaultShims.filter { !enabledDefaults.contains($0) }
        var shims: [String: Any] = [:]
        if !normalizedCustom.isEmpty { shims["add"] = normalizedCustom }
        if !removed.isEmpty { shims["remove"] = removed }
        return try ConfigJSON.edit(data) { root in
            root["shims"] = shims.isEmpty ? nil : shims
        }
    }

    public static func normalize(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains("\0") else { return nil }
        return trimmed
    }

    private var normalizedCustom: [String] {
        var seen = Set<String>()
        return custom.compactMap(Self.normalize).filter { !Classifier.defaultShims.contains($0) && seen.insert($0).inserted }
    }
}
