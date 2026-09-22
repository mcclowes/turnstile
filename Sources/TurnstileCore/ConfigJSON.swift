import Foundation

/// Edits the global config's JSON in place, so settings screens change their own keys and keep the rest.
public enum ConfigJSON {
    public static func edit(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var root: [String: Any] = [:]
        if !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            root = object
        }
        change(&root)
        var encoded = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        encoded.append(0x0A)
        return encoded
    }
}

extension Dictionary where Key == String, Value == Any {
    /// Sets or removes `key` inside the object at `section`, dropping the object once it's empty.
    mutating func set(_ value: Any?, forKey key: String, in section: String) {
        var object = self[section] as? [String: Any] ?? [:]
        object[key] = value
        self[section] = object.isEmpty ? nil : object
    }
}
