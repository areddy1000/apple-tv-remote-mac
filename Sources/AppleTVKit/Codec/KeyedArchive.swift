import Foundation

/// A property list value for the binary plist codec.
/// Dictionaries keep their key order.
public indirect enum PlistValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case real(Double)
    case string(String)
    case data(Data)
    case uid(UInt64)
    case array([PlistValue])
    case dict([(String, PlistValue)])

    public static func == (lhs: PlistValue, rhs: PlistValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.real(let a), .real(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.data(let a), .data(let b)): return a == b
        case (.uid(let a), .uid(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.dict(let a), .dict(let b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    /// Looks up a key in a dictionary value.
    public subscript(key: String) -> PlistValue? {
        guard case .dict(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    /// Looks up an index in an array value.
    public subscript(index: Int) -> PlistValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var dataValue: Data? {
        if case .data(let value) = self { return value }
        return nil
    }

    public var uidValue: UInt64? {
        if case .uid(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }
}

/// Encodes and decodes the binary plist format (`bplist00`).
/// It supports the types that NSKeyedArchiver archives use, UIDs included.
public enum BinaryPlist {
    public enum CodecError: Error {
        case badHeader
        case badTrailer
        case badMarker(UInt8)
        case truncated
        case unsupportedType
    }

    // MARK: Encode

    public static func encode(_ root: PlistValue) -> Data {
        var entries: [Entry] = []
        _ = flatten(root, into: &entries)
        let refSize = byteSize(for: UInt64(entries.count))

        var body = Data("bplist00".utf8)
        var offsets: [UInt64] = []
        for entry in entries {
            offsets.append(UInt64(body.count))
            write(entry, into: &body, refSize: refSize)
        }

        let tableOffset = UInt64(body.count)
        let offsetSize = byteSize(for: tableOffset)
        for offset in offsets {
            appendInteger(offset, size: offsetSize, to: &body)
        }

        body.append(contentsOf: [0, 0, 0, 0, 0, 0])
        body.append(offsetSize)
        body.append(refSize)
        appendInteger(UInt64(entries.count), size: 8, to: &body)
        appendInteger(0, size: 8, to: &body)
        appendInteger(tableOffset, size: 8, to: &body)
        return body
    }

    /// One object in the table. `refs` holds the child indices.
    /// A dictionary lists its key indices first and then its value indices.
    private struct Entry {
        var value: PlistValue
        var refs: [Int]
    }

    /// Adds the value and its children to the table in pre-order.
    /// Returns the index of the value.
    private static func flatten(_ value: PlistValue, into entries: inout [Entry]) -> Int {
        let index = entries.count
        entries.append(Entry(value: value, refs: []))
        switch value {
        case .array(let items):
            var refs: [Int] = []
            for item in items { refs.append(flatten(item, into: &entries)) }
            entries[index].refs = refs
        case .dict(let pairs):
            var keyRefs: [Int] = []
            for (key, _) in pairs {
                keyRefs.append(entries.count)
                entries.append(Entry(value: .string(key), refs: []))
            }
            var valueRefs: [Int] = []
            for (_, item) in pairs { valueRefs.append(flatten(item, into: &entries)) }
            entries[index].refs = keyRefs + valueRefs
        default:
            break
        }
        return index
    }

    /// Writes one object with its marker and its child references.
    private static func write(_ entry: Entry, into body: inout Data, refSize: UInt8) {
        switch entry.value {
        case .null:
            body.append(0x00)
        case .bool(let flag):
            body.append(flag ? 0x09 : 0x08)
        case .int(let number):
            if number >= 0 && number <= 0xFF {
                body.append(0x10); body.append(UInt8(number))
            } else if number >= 0 && number <= 0xFFFF {
                body.append(0x11); appendInteger(UInt64(number), size: 2, to: &body)
            } else if number >= 0 && number <= 0xFFFF_FFFF {
                body.append(0x12); appendInteger(UInt64(number), size: 4, to: &body)
            } else {
                body.append(0x13); appendInteger(UInt64(bitPattern: number), size: 8, to: &body)
            }
        case .real(let number):
            body.append(0x23)
            appendInteger(number.bitPattern, size: 8, to: &body)
        case .string(let text):
            writeString(text, into: &body)
        case .data(let bytes):
            writeMarker(0x40, count: bytes.count, to: &body)
            body.append(bytes)
        case .uid(let number):
            let size = byteSize(for: number)
            body.append(0x80 | (size - 1))
            appendInteger(number, size: size, to: &body)
        case .array(let items):
            writeMarker(0xA0, count: items.count, to: &body)
            for ref in entry.refs { appendInteger(UInt64(ref), size: refSize, to: &body) }
        case .dict(let pairs):
            writeMarker(0xD0, count: pairs.count, to: &body)
            for ref in entry.refs { appendInteger(UInt64(ref), size: refSize, to: &body) }
        }
    }

    private static func writeString(_ text: String, into body: inout Data) {
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            writeMarker(0x50, count: text.utf8.count, to: &body)
            body.append(contentsOf: Array(text.utf8))
        } else {
            let units = Array(text.utf16)
            writeMarker(0x60, count: units.count, to: &body)
            for unit in units { appendInteger(UInt64(unit), size: 2, to: &body) }
        }
    }

    private static func writeMarker(_ base: UInt8, count: Int, to body: inout Data) {
        if count < 15 {
            body.append(base | UInt8(count))
        } else {
            body.append(base | 0x0F)
            let size = byteSize(for: UInt64(count))
            body.append(0x10 | UInt8(size.trailingZeroBitCount))
            appendInteger(UInt64(count), size: size, to: &body)
        }
    }

    private static func byteSize(for number: UInt64) -> UInt8 {
        if number <= 0xFF { return 1 }
        if number <= 0xFFFF { return 2 }
        if number <= 0xFFFF_FFFF { return 4 }
        return 8
    }

    private static func appendInteger(_ number: UInt64, size: UInt8, to body: inout Data) {
        for shift in stride(from: Int(size) - 1, through: 0, by: -1) {
            body.append(UInt8((number >> (UInt64(shift) * 8)) & 0xFF))
        }
    }

    // MARK: Decode

    public static func decode(_ data: Data) throws -> PlistValue {
        guard data.count >= 40, data.prefix(8) == Data("bplist00".utf8) else { throw CodecError.badHeader }
        let trailer = data.suffix(32)
        let base = trailer.startIndex
        let offsetSize = Int(trailer[base + 6])
        let refSize = Int(trailer[base + 7])
        let objectCount = Int(readInteger(data, at: base + 8, size: 8))
        let topObject = Int(readInteger(data, at: base + 16, size: 8))
        let tableOffset = Int(readInteger(data, at: base + 24, size: 8))
        guard offsetSize > 0, refSize > 0, objectCount > 0 else { throw CodecError.badTrailer }
        guard tableOffset + objectCount * offsetSize <= data.count - 32 else { throw CodecError.badTrailer }

        var offsets: [Int] = []
        offsets.reserveCapacity(objectCount)
        for index in 0..<objectCount {
            let position = data.startIndex + tableOffset + index * offsetSize
            offsets.append(Int(readInteger(data, at: position, size: offsetSize)))
        }
        var reader = Reader(data: data, offsets: offsets, refSize: refSize)
        return try reader.object(at: topObject)
    }

    private static func readInteger(_ data: Data, at position: Int, size: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<size {
            value = (value << 8) | UInt64(data[position + index])
        }
        return value
    }

    private struct Reader {
        let data: Data
        let offsets: [Int]
        let refSize: Int

        mutating func object(at index: Int) throws -> PlistValue {
            guard offsets.indices.contains(index) else { throw CodecError.truncated }
            var position = data.startIndex + offsets[index]
            guard position < data.endIndex else { throw CodecError.truncated }
            let marker = data[position]
            position += 1
            let kind = marker & 0xF0
            let low = Int(marker & 0x0F)

            switch kind {
            case 0x00:
                switch marker {
                case 0x00: return .null
                case 0x08: return .bool(false)
                case 0x09: return .bool(true)
                default: throw CodecError.badMarker(marker)
                }
            case 0x10:
                let size = 1 << low
                try ensure(position, size)
                let raw = BinaryPlist.readInteger(data, at: position, size: size)
                return .int(size == 8 ? Int64(bitPattern: raw) : Int64(raw))
            case 0x20:
                let size = 1 << low
                try ensure(position, size)
                let raw = BinaryPlist.readInteger(data, at: position, size: size)
                if size == 8 { return .real(Double(bitPattern: raw)) }
                if size == 4 { return .real(Double(Float(bitPattern: UInt32(raw)))) }
                throw CodecError.unsupportedType
            case 0x40:
                let count = try length(low, &position)
                try ensure(position, count)
                return .data(Data(data[position..<position + count]))
            case 0x50:
                let count = try length(low, &position)
                try ensure(position, count)
                guard let text = String(data: data[position..<position + count], encoding: .ascii) else {
                    throw CodecError.unsupportedType
                }
                return .string(text)
            case 0x60:
                let count = try length(low, &position)
                try ensure(position, count * 2)
                var units: [UInt16] = []
                units.reserveCapacity(count)
                for item in 0..<count {
                    units.append(UInt16(BinaryPlist.readInteger(data, at: position + item * 2, size: 2)))
                }
                return .string(String(utf16CodeUnits: units, count: units.count))
            case 0x80:
                let size = low + 1
                try ensure(position, size)
                return .uid(BinaryPlist.readInteger(data, at: position, size: size))
            case 0xA0:
                let count = try length(low, &position)
                try ensure(position, count * refSize)
                var items: [PlistValue] = []
                for item in 0..<count {
                    let ref = Int(BinaryPlist.readInteger(data, at: position + item * refSize, size: refSize))
                    items.append(try object(at: ref))
                }
                return .array(items)
            case 0xD0:
                let count = try length(low, &position)
                try ensure(position, count * refSize * 2)
                var pairs: [(String, PlistValue)] = []
                for item in 0..<count {
                    let keyRef = Int(BinaryPlist.readInteger(data, at: position + item * refSize, size: refSize))
                    let valueRef = Int(BinaryPlist.readInteger(data, at: position + (count + item) * refSize, size: refSize))
                    guard let key = try object(at: keyRef).stringValue else { throw CodecError.unsupportedType }
                    pairs.append((key, try object(at: valueRef)))
                }
                return .dict(pairs)
            default:
                throw CodecError.badMarker(marker)
            }
        }

        private func ensure(_ position: Int, _ count: Int) throws {
            guard position + count <= data.endIndex else { throw CodecError.truncated }
        }

        private func length(_ low: Int, _ position: inout Int) throws -> Int {
            guard low == 0x0F else { return low }
            guard position < data.endIndex else { throw CodecError.truncated }
            let marker = data[position]
            position += 1
            guard marker & 0xF0 == 0x10 else { throw CodecError.badMarker(marker) }
            let size = 1 << Int(marker & 0x0F)
            try ensure(position, size)
            let value = Int(BinaryPlist.readInteger(data, at: position, size: size))
            position += size
            return value
        }
    }
}

/// Builds an NSKeyedArchiver style archive as a binary plist.
/// The caller supplies the object table and the top references.
public struct KeyedArchiveBuilder: Sendable {
    public var archiver: String
    public var top: [(String, UInt64)]
    public var objects: [PlistValue]

    public init(archiver: String = "NSKeyedArchiver", top: [(String, UInt64)], objects: [PlistValue]) {
        self.archiver = archiver
        self.top = top
        self.objects = objects
    }

    /// The archive as a plist value.
    public var plist: PlistValue {
        .dict([
            ("$version", .int(100_000)),
            ("$archiver", .string(archiver)),
            ("$top", .dict(top.map { ($0.0, .uid($0.1)) })),
            ("$objects", .array(objects)),
        ])
    }

    /// The archive as binary plist bytes.
    public func encode() -> Data {
        BinaryPlist.encode(plist)
    }
}

/// Reads properties from a keyed archive by UID references.
public enum KeyedArchiveReader {
    /// Follows a key path from `$top`. Each UID resolves to its object.
    /// The result is nil when a key is absent.
    public static func property(in archive: Data, path: [String]) -> PlistValue? {
        guard let root = try? BinaryPlist.decode(archive) else { return nil }
        guard case .array(let objects)? = root["$objects"] else { return nil }
        guard var element = root["$top"] else { return nil }
        for key in path {
            guard let next = element[key] else { return nil }
            element = next
            if let uid = element.uidValue {
                guard objects.indices.contains(Int(uid)) else { return nil }
                element = objects[Int(uid)]
            }
        }
        return element
    }

    /// Returns every object in the archive.
    public static func objects(in archive: Data) -> [PlistValue] {
        guard let root = try? BinaryPlist.decode(archive), case .array(let objects)? = root["$objects"] else {
            return []
        }
        return objects
    }
}
