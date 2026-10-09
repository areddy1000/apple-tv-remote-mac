import Foundation

/// Long-term pairing credentials for one accessory.
/// The struct holds a private key. Never log it or print it.
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
}

extension Data {
    /// Lowercase hex with no separators.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Parses hex with no separators. Returns nil on a bad character or an odd length.
    init?(hexString: String) {
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
