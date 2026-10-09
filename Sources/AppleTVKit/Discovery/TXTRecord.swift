import Foundation
import Network

/// Parses Bonjour TXT records into a dictionary.
public enum TXTRecord {
    /// Reads the key and value pairs from a Network framework TXT record.
    public static func parse(_ txt: NWTXTRecord) -> [String: String] {
        txt.dictionary
    }

    /// Reads raw TXT data. Each entry has a one byte length and then "key=value".
    /// An entry with no "=" maps to an empty string.
    public static func parse(raw data: Data) -> [String: String] {
        var result: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index])
            index += 1
            guard length > 0 else { continue }
            let end = min(index + length, data.endIndex)
            let entry = data[index..<end]
            index = end
            guard let text = String(data: entry, encoding: .utf8) else { continue }
            if let equals = text.firstIndex(of: "=") {
                let key = String(text[..<equals])
                let value = String(text[text.index(after: equals)...])
                result[key] = value
            } else {
                result[text] = ""
            }
        }
        return result
    }
}
