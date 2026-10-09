import Foundation

/// Long-term pairing credentials for one accessory.
/// The string form matches pyatv: `ltpk:ltsk:accessoryID:clientID` as hex.
public struct HAPCredentials: Codable, Sendable, Equatable {
    /// The accessory long-term Ed25519 public key.
    public var ltpk: Data
    /// Our long-term Ed25519 private key, 32 raw bytes.
    public var ltsk: Data
    /// The accessory pairing identifier bytes.
    public var accessoryID: Data
    /// Our pairing identifier bytes.
    public var clientID: Data

    public init(ltpk: Data, ltsk: Data, accessoryID: Data, clientID: Data) {
        self.ltpk = ltpk
        self.ltsk = ltsk
        self.accessoryID = accessoryID
        self.clientID = clientID
    }

    /// The colon separated hex form.
    public var description: String {
        [ltpk, ltsk, accessoryID, clientID].map { $0.hexString }.joined(separator: ":")
    }

    /// Parses the colon separated hex form. Returns nil when the form is wrong.
    public init?(string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { Data(hexString: String($0)) }
        guard values.count == 4 else { return nil }
        self.init(ltpk: values[0], ltsk: values[1], accessoryID: values[2], clientID: values[3])
    }

    /// The client identifier as a string.
    public var clientIDString: String { String(decoding: clientID, as: UTF8.self) }

    /// The accessory identifier as a string.
    public var accessoryIDString: String { String(decoding: accessoryID, as: UTF8.self) }
}

extension Data {
    /// Lowercase hex with no separators.
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Parses hex with no separators. Returns nil on a bad character or odd length.
    public init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = Data.hexValue(chars[index]), let low = Data.hexValue(chars[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        self = out
    }

    private static func hexValue(_ char: UInt8) -> UInt8? {
        switch char {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return char - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return char - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return char - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
