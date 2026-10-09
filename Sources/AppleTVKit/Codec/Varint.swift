import Foundation

public enum VarintError: Error, Sendable, Equatable {
    case truncated
    case overflow
}

/// Base-128 varint, as protobuf uses it.
public enum Varint {
    public static func encode(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// Reads one varint from `data` at `at`. Advances `at` past it.
    public static func decode(_ data: Data, at: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = data.startIndex + at
        while true {
            guard index < data.endIndex else { throw VarintError.truncated }
            guard shift < 64 else { throw VarintError.overflow }
            let byte = data[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        at = index - data.startIndex
        return result
    }
}
