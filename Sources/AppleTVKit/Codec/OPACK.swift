import Foundation

/// One OPACK value. OPACK is the binary dictionary format of the Companion protocol.
public indirect enum OPACKValue: Sendable, Equatable {
    case bool(Bool)
    case null
    case int(Int64)
    case float(Float)
    case double(Double)
    case string(String)
    case data(Data)
    case uuid(UUID)
    case array([OPACKValue])
    case dictionary([String: OPACKValue])

    public subscript(key: String) -> OPACKValue? {
        if case .dictionary(let dict) = self { return dict[key] }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(exactly: v)
        case .float(let v): return Int64(exactly: v)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .float(let v): return Double(v)
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var dataValue: Data? {
        if case .data(let v) = self { return v }
        return nil
    }

    public var uuidValue: UUID? {
        if case .uuid(let v) = self { return v }
        return nil
    }

    public var arrayValue: [OPACKValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var dictValue: [String: OPACKValue]? {
        if case .dictionary(let v) = self { return v }
        return nil
    }
}

extension OPACKValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(dictionaryLiteral elements: (String, OPACKValue)...) {
        var dict: [String: OPACKValue] = [:]
        for (k, v) in elements { dict[k] = v }
        self = .dictionary(dict)
    }
    public init(arrayLiteral elements: OPACKValue...) { self = .array(elements) }
}

public enum OPACKError: Error, Sendable, Equatable {
    case truncated
    case unknownMarker(UInt8)
    case badPointer(Int)
    case badString
    case badKey
}

/// Encodes and decodes OPACK. The layout follows the pyatv reference.
public enum OPACK {
    // MARK: Encode

    public static func encode(_ value: OPACKValue) -> Data {
        var encoder = Encoder()
        encoder.write(value)
        return encoder.out
    }

    private struct Encoder {
        var out = Data()
        /// Objects that a pointer can reference. Index matches the decoder list.
        var objects: [Data] = []

        mutating func write(_ value: OPACKValue) {
            switch value {
            case .bool(let b):
                out.append(b ? 0x01 : 0x02)
            case .null:
                out.append(0x04)
            case .int(let i):
                writeInt(i)
            case .float(let f):
                var chunk = Data([0x35])
                withUnsafeBytes(of: f.bitPattern.littleEndian) { chunk.append(contentsOf: $0) }
                writeObject(chunk)
            case .double(let d):
                var chunk = Data([0x36])
                withUnsafeBytes(of: d.bitPattern.littleEndian) { chunk.append(contentsOf: $0) }
                writeObject(chunk)
            case .string(let s):
                let bytes = Data(s.utf8)
                var chunk = Data()
                if bytes.count <= 32 {
                    chunk.append(0x40 + UInt8(bytes.count))
                } else if bytes.count <= 0xFF {
                    chunk.append(0x61)
                    chunk.append(UInt8(bytes.count))
                } else if bytes.count <= 0xFFFF {
                    chunk.append(0x62)
                    chunk.append(littleEndian: UInt64(bytes.count), width: 2)
                } else if bytes.count <= 0xFF_FFFF {
                    chunk.append(0x63)
                    chunk.append(littleEndian: UInt64(bytes.count), width: 3)
                } else {
                    chunk.append(0x64)
                    chunk.append(littleEndian: UInt64(bytes.count), width: 4)
                }
                chunk.append(bytes)
                writeObject(chunk)
            case .data(let d):
                var chunk = Data()
                if d.count <= 32 {
                    chunk.append(0x70 + UInt8(d.count))
                } else if d.count <= 0xFF {
                    chunk.append(0x91)
                    chunk.append(UInt8(d.count))
                } else if d.count <= 0xFFFF {
                    chunk.append(0x92)
                    chunk.append(littleEndian: UInt64(d.count), width: 2)
                } else if d.count <= 0xFFFF_FFFF {
                    chunk.append(0x93)
                    chunk.append(littleEndian: UInt64(d.count), width: 4)
                } else {
                    chunk.append(0x94)
                    chunk.append(littleEndian: UInt64(d.count), width: 8)
                }
                chunk.append(d)
                writeObject(chunk)
            case .uuid(let u):
                var chunk = Data([0x05])
                withUnsafeBytes(of: u.uuid) { chunk.append(contentsOf: $0) }
                writeObject(chunk)
            case .array(let items):
                if items.count < 15 {
                    out.append(0xD0 + UInt8(items.count))
                    for item in items { write(item) }
                } else {
                    out.append(0xDF)
                    for item in items { write(item) }
                    out.append(0x03)
                }
            case .dictionary(let dict):
                let keys = dict.keys.sorted()
                if keys.count < 15 {
                    out.append(0xE0 + UInt8(keys.count))
                    for key in keys {
                        write(.string(key))
                        write(dict[key]!)
                    }
                } else {
                    out.append(0xEF)
                    for key in keys {
                        write(.string(key))
                        write(dict[key]!)
                    }
                    out.append(0x03)
                }
            }
        }

        mutating func writeInt(_ i: Int64) {
            if i == -1 {
                out.append(0x07)
                return
            }
            if i >= 0 && i <= 39 {
                out.append(0x08 + UInt8(i))
                return
            }
            var chunk = Data()
            if i < 0 {
                // Negative values use the full signed width.
                chunk.append(0x33)
                chunk.append(littleEndian: UInt64(bitPattern: i), width: 8)
            } else if i <= 0xFF {
                chunk.append(0x30)
                chunk.append(UInt8(i))
            } else if i <= 0xFFFF {
                chunk.append(0x31)
                chunk.append(littleEndian: UInt64(i), width: 2)
            } else if i <= 0xFFFF_FFFF {
                chunk.append(0x32)
                chunk.append(littleEndian: UInt64(i), width: 4)
            } else {
                chunk.append(0x33)
                chunk.append(littleEndian: UInt64(i), width: 8)
            }
            writeObject(chunk)
        }

        /// Writes a pointer when the same object was written before. Otherwise writes the object.
        mutating func writeObject(_ chunk: Data) {
            if let index = objects.firstIndex(of: chunk) {
                if index <= 0x20 {
                    out.append(0xA0 + UInt8(index))
                } else if index <= 0xFF {
                    out.append(0xC1)
                    out.append(UInt8(index))
                } else if index <= 0xFFFF {
                    out.append(0xC2)
                    out.append(littleEndian: UInt64(index), width: 2)
                } else if index <= 0xFF_FFFF {
                    out.append(0xC3)
                    out.append(littleEndian: UInt64(index), width: 3)
                } else {
                    out.append(0xC4)
                    out.append(littleEndian: UInt64(index), width: 4)
                }
                return
            }
            objects.append(chunk)
            out.append(chunk)
        }
    }

    // MARK: Decode

    public static func decode(_ data: Data) throws -> OPACKValue {
        var decoder = Decoder(bytes: [UInt8](data))
        return try decoder.read()
    }

    private struct Decoder {
        let bytes: [UInt8]
        var pos = 0
        /// Decoded objects that a pointer can reference.
        var objects: [OPACKValue] = []

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard pos + n <= bytes.count else { throw OPACKError.truncated }
            let slice = bytes[pos..<(pos + n)]
            pos += n
            return slice
        }

        mutating func takeLittleEndian(width: Int) throws -> UInt64 {
            let slice = try take(width)
            var value: UInt64 = 0
            for (i, b) in slice.enumerated() {
                value |= UInt64(b) << (8 * UInt64(i))
            }
            return value
        }

        mutating func remember(_ value: OPACKValue) -> OPACKValue {
            objects.append(value)
            return value
        }

        mutating func read() throws -> OPACKValue {
            guard pos < bytes.count else { throw OPACKError.truncated }
            let marker = bytes[pos]
            pos += 1
            switch marker {
            case 0x01: return .bool(true)
            case 0x02: return .bool(false)
            case 0x04: return .null
            case 0x05:
                let raw = try take(16)
                let tuple = raw.withUnsafeBytes { $0.load(as: uuid_t.self) }
                return remember(.uuid(UUID(uuid: tuple)))
            case 0x06:
                // Absolute time. The reference reads 8 bytes and keeps the raw value.
                let raw = try takeLittleEndian(width: 8)
                return remember(.double(Double(bitPattern: raw)))
            case 0x07: return .int(-1)
            case 0x08...0x2F: return .int(Int64(marker - 0x08))
            case 0x30...0x33:
                let width = 1 << Int(marker - 0x30)
                let raw = try takeLittleEndian(width: width)
                let value: Int64 = width == 8 ? Int64(bitPattern: raw) : Int64(raw)
                return remember(.int(value))
            case 0x35:
                let raw = try takeLittleEndian(width: 4)
                return remember(.float(Float(bitPattern: UInt32(raw))))
            case 0x36:
                let raw = try takeLittleEndian(width: 8)
                return remember(.double(Double(bitPattern: raw)))
            case 0x40...0x60:
                return try remember(readString(count: Int(marker - 0x40)))
            case 0x61...0x64:
                let count = try takeLittleEndian(width: Int(marker - 0x60))
                return try remember(readString(count: Int(count)))
            case 0x6F:
                var end = pos
                while end < bytes.count && bytes[end] != 0 { end += 1 }
                guard end < bytes.count else { throw OPACKError.truncated }
                let value = try readString(count: end - pos)
                pos += 1
                return remember(value)
            case 0x70...0x90:
                let raw = try take(Int(marker - 0x70))
                return remember(.data(Data(raw)))
            case 0x91...0x94:
                let widths = [1, 2, 4, 8]
                let count = try takeLittleEndian(width: widths[Int(marker - 0x91)])
                let raw = try take(Int(count))
                return remember(.data(Data(raw)))
            case 0xA0...0xC0:
                return try pointer(Int(marker - 0xA0))
            case 0xC1...0xC4:
                let index = try takeLittleEndian(width: Int(marker - 0xC0))
                return try pointer(Int(index))
            case 0xD0...0xDE:
                var items: [OPACKValue] = []
                for _ in 0..<Int(marker - 0xD0) { items.append(try read()) }
                return .array(items)
            case 0xDF:
                var items: [OPACKValue] = []
                while try peek() != 0x03 { items.append(try read()) }
                pos += 1
                return .array(items)
            case 0xE0...0xEE:
                var dict: [String: OPACKValue] = [:]
                for _ in 0..<Int(marker - 0xE0) {
                    let key = try read()
                    guard let k = key.stringValue else { throw OPACKError.badKey }
                    dict[k] = try read()
                }
                return .dictionary(dict)
            case 0xEF:
                var dict: [String: OPACKValue] = [:]
                while try peek() != 0x03 {
                    let key = try read()
                    guard let k = key.stringValue else { throw OPACKError.badKey }
                    dict[k] = try read()
                }
                pos += 1
                return .dictionary(dict)
            default:
                throw OPACKError.unknownMarker(marker)
            }
        }

        func peek() throws -> UInt8 {
            guard pos < bytes.count else { throw OPACKError.truncated }
            return bytes[pos]
        }

        func pointer(_ index: Int) throws -> OPACKValue {
            guard index < objects.count else { throw OPACKError.badPointer(index) }
            return objects[index]
        }

        mutating func readString(count: Int) throws -> OPACKValue {
            let raw = try take(count)
            guard let s = String(bytes: raw, encoding: .utf8) else { throw OPACKError.badString }
            return .string(s)
        }
    }
}

extension Data {
    /// Appends `value` as `width` little-endian bytes.
    mutating func append(littleEndian value: UInt64, width: Int) {
        for i in 0..<width {
            append(UInt8((value >> (8 * UInt64(i))) & 0xFF))
        }
    }
}
