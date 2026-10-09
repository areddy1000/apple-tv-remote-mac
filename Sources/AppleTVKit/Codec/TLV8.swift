import Foundation

/// HAP TLV8 tags.
public enum TLV8Tag: UInt8, Sendable {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case state = 0x06
    case error = 0x07
    case retryDelay = 0x08
    case certificate = 0x09
    case signature = 0x0A
    case permissions = 0x0B
    case fragmentData = 0x0C
    case fragmentLast = 0x0D
    case name = 0x11
    case flags = 0x13
    case separator = 0xFF
}

/// HAP pairing error codes carried in the `error` tag.
public enum TLV8Error: UInt8, Error, Sendable {
    case unknown = 0x01
    case authentication = 0x02
    case backOff = 0x03
    case maxPeers = 0x04
    case maxTries = 0x05
    case unavailable = 0x06
    case busy = 0x07
}

public enum TLV8DecodeError: Error, Sendable, Equatable {
    case truncated
}

/// Encodes and decodes TLV8. A value longer than 255 bytes spans repeated tags.
public struct TLV8: Sendable {
    public static func encode(_ items: [(UInt8, Data)]) -> Data {
        var out = Data()
        for (tag, value) in items {
            if value.isEmpty {
                out.append(tag)
                out.append(0)
                continue
            }
            var offset = 0
            while offset < value.count {
                let chunk = min(255, value.count - offset)
                out.append(tag)
                out.append(UInt8(chunk))
                out.append(value[value.startIndex + offset..<value.startIndex + offset + chunk])
                offset += chunk
            }
        }
        return out
    }

    public static func encode(_ items: [(TLV8Tag, Data)]) -> Data {
        encode(items.map { ($0.0.rawValue, $0.1) })
    }

    public static func decode(_ data: Data) throws -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        let bytes = [UInt8](data)
        var pos = 0
        var lastTag: UInt8? = nil
        while pos < bytes.count {
            guard pos + 2 <= bytes.count else { throw TLV8DecodeError.truncated }
            let tag = bytes[pos]
            let length = Int(bytes[pos + 1])
            pos += 2
            guard pos + length <= bytes.count else { throw TLV8DecodeError.truncated }
            let value = Data(bytes[pos..<(pos + length)])
            pos += length
            if lastTag == tag, result[tag] != nil {
                result[tag]!.append(value)
            } else {
                result[tag] = value
            }
            lastTag = tag
        }
        return result
    }

    /// Returns the HAP error carried in a decoded TLV, when present.
    public static func error(in decoded: [UInt8: Data]) -> TLV8Error? {
        guard let raw = decoded[TLV8Tag.error.rawValue]?.first else { return nil }
        return TLV8Error(rawValue: raw) ?? .unknown
    }
}

extension Dictionary where Key == UInt8, Value == Data {
    public subscript(tag: TLV8Tag) -> Data? {
        self[tag.rawValue]
    }
}
