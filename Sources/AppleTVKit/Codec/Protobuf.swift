import Foundation

public enum ProtobufError: Error, Sendable, Equatable {
    case truncated
    case unsupportedWireType(Int)
}

/// One decoded field value.
public enum ProtobufField: Sendable, Equatable {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case lengthDelimited(Data)
}

/// Builds a protobuf message byte by byte.
public struct ProtobufWriter: Sendable {
    public private(set) var data = Data()

    public init() {}

    private mutating func tag(field: Int, wireType: UInt64) {
        data.append(Varint.encode(UInt64(field) << 3 | wireType))
    }

    public mutating func varint(field: Int, value: UInt64) {
        tag(field: field, wireType: 0)
        data.append(Varint.encode(value))
    }

    public mutating func bool(field: Int, value: Bool) {
        varint(field: field, value: value ? 1 : 0)
    }

    public mutating func int32(field: Int, value: Int32) {
        // Negative int32 values use the full 64-bit two's complement form.
        varint(field: field, value: UInt64(bitPattern: Int64(value)))
    }

    public mutating func uint32(field: Int, value: UInt32) {
        varint(field: field, value: UInt64(value))
    }

    public mutating func int64(field: Int, value: Int64) {
        varint(field: field, value: UInt64(bitPattern: value))
    }

    public mutating func uint64(field: Int, value: UInt64) {
        varint(field: field, value: value)
    }

    public mutating func double(field: Int, value: Double) {
        tag(field: field, wireType: 1)
        data.append(littleEndian: value.bitPattern, width: 8)
    }

    public mutating func float(field: Int, value: Float) {
        tag(field: field, wireType: 5)
        data.append(littleEndian: UInt64(value.bitPattern), width: 4)
    }

    public mutating func string(field: Int, value: String) {
        bytes(field: field, value: Data(value.utf8))
    }

    public mutating func bytes(field: Int, value: Data) {
        tag(field: field, wireType: 2)
        data.append(Varint.encode(UInt64(value.count)))
        data.append(value)
    }

    public mutating func message(field: Int, writer: ProtobufWriter) {
        bytes(field: field, value: writer.data)
    }
}

/// Reads a protobuf message into fields keyed by number.
public struct ProtobufReader: Sendable {
    public let fields: [Int: [ProtobufField]]

    public init(_ data: Data) throws {
        var fields: [Int: [ProtobufField]] = [:]
        var pos = 0
        while pos < data.count {
            let key = try Varint.decode(data, at: &pos)
            let field = Int(key >> 3)
            let wireType = Int(key & 0x07)
            let value: ProtobufField
            switch wireType {
            case 0:
                value = .varint(try Varint.decode(data, at: &pos))
            case 1:
                guard pos + 8 <= data.count else { throw ProtobufError.truncated }
                value = .fixed64(Self.littleEndian(data, at: pos, width: 8))
                pos += 8
            case 2:
                let length = Int(try Varint.decode(data, at: &pos))
                guard pos + length <= data.count else { throw ProtobufError.truncated }
                let start = data.startIndex + pos
                value = .lengthDelimited(Data(data[start..<(start + length)]))
                pos += length
            case 5:
                guard pos + 4 <= data.count else { throw ProtobufError.truncated }
                value = .fixed32(UInt32(Self.littleEndian(data, at: pos, width: 4)))
                pos += 4
            default:
                throw ProtobufError.unsupportedWireType(wireType)
            }
            fields[field, default: []].append(value)
        }
        self.fields = fields
    }

    private static func littleEndian(_ data: Data, at pos: Int, width: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<width {
            value |= UInt64(data[data.startIndex + pos + i]) << (8 * UInt64(i))
        }
        return value
    }

    private func last(_ field: Int) -> ProtobufField? {
        fields[field]?.last
    }

    public func uint64(_ field: Int) -> UInt64? {
        if case .varint(let v) = last(field) { return v }
        return nil
    }

    public func int64(_ field: Int) -> Int64? {
        uint64(field).map { Int64(bitPattern: $0) }
    }

    public func int32(_ field: Int) -> Int32? {
        uint64(field).map { Int32(truncatingIfNeeded: $0) }
    }

    public func uint32(_ field: Int) -> UInt32? {
        uint64(field).map { UInt32(truncatingIfNeeded: $0) }
    }

    public func bool(_ field: Int) -> Bool? {
        uint64(field).map { $0 != 0 }
    }

    public func double(_ field: Int) -> Double? {
        if case .fixed64(let v) = last(field) { return Double(bitPattern: v) }
        return nil
    }

    public func float(_ field: Int) -> Float? {
        if case .fixed32(let v) = last(field) { return Float(bitPattern: v) }
        return nil
    }

    public func bytes(_ field: Int) -> Data? {
        if case .lengthDelimited(let v) = last(field) { return v }
        return nil
    }

    public func string(_ field: Int) -> String? {
        bytes(field).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func strings(_ field: Int) -> [String] {
        (fields[field] ?? []).compactMap {
            if case .lengthDelimited(let d) = $0 { return String(data: d, encoding: .utf8) }
            return nil
        }
    }

    public func message(_ field: Int) -> ProtobufReader? {
        bytes(field).flatMap { try? ProtobufReader($0) }
    }

    public func messages(_ field: Int) -> [ProtobufReader] {
        (fields[field] ?? []).compactMap {
            if case .lengthDelimited(let d) = $0 { return try? ProtobufReader(d) }
            return nil
        }
    }
}
