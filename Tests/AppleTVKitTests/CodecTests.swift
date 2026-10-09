import Foundation
import Testing
@testable import AppleTVKit

@Suite struct CodecTests {
    // MARK: OPACK

    @Test func opackRoundTripsEveryCase() throws {
        let value: OPACKValue = .dictionary([
            "t": .bool(true),
            "f": .bool(false),
            "n": .null,
            "small": .int(39),
            "neg1": .int(-1),
            "neg": .int(-5000),
            "u8": .int(200),
            "u16": .int(60000),
            "u32": .int(4_000_000_000),
            "u64": .int(Int64.max),
            "flt": .float(1.5),
            "dbl": .double(1000.25),
            "s": .string("hello"),
            "long": .string(String(repeating: "x", count: 300)),
            "d": .data(Data([1, 2, 3])),
            "longd": .data(Data(repeating: 7, count: 70_000)),
            "uuid": .uuid(UUID()),
            "arr": .array([.int(1), .string("two"), .array([])]),
            "bigarr": .array((0..<20).map { .int(Int64($0)) }),
            "nested": .dictionary(["a": .dictionary([:])]),
        ])
        let encoded = OPACK.encode(value)
        let decoded = try OPACK.decode(encoded)
        #expect(decoded == value)
    }

    @Test func opackEncodesKnownBytes() {
        // {"_i": "_hidC"}: dictionary with one pair, two short strings.
        let value: OPACKValue = ["_i": "_hidC"]
        let expected = Data([0xE1, 0x42, 0x5F, 0x69, 0x45, 0x5F, 0x68, 0x69, 0x64, 0x43])
        #expect(OPACK.encode(value) == expected)
        #expect(OPACK.encode(.int(0)) == Data([0x08]))
        #expect(OPACK.encode(.int(-1)) == Data([0x07]))
        #expect(OPACK.encode(.int(255)) == Data([0x30, 0xFF]))
        #expect(OPACK.encode(.int(256)) == Data([0x31, 0x00, 0x01]))
        #expect(OPACK.encode(.bool(true)) == Data([0x01]))
        #expect(OPACK.encode(.null) == Data([0x04]))
    }

    @Test func opackDecodesTouchStart() throws {
        // {"_width": 1000.0, "_height": 1000.0, "_tFl": 0}
        var bytes = Data([0xE3])
        bytes.append(contentsOf: [0x46] + Array("_width".utf8))
        bytes.append(0x36)
        bytes.append(littleEndian: (1000.0 as Double).bitPattern, width: 8)
        bytes.append(contentsOf: [0x47] + Array("_height".utf8))
        bytes.append(0x36)
        bytes.append(littleEndian: (1000.0 as Double).bitPattern, width: 8)
        bytes.append(contentsOf: [0x44] + Array("_tFl".utf8))
        bytes.append(0x08)
        let decoded = try OPACK.decode(bytes)
        #expect(decoded["_width"]?.doubleValue == 1000.0)
        #expect(decoded["_height"]?.doubleValue == 1000.0)
        #expect(decoded["_tFl"]?.intValue == 0)
    }

    @Test func opackDecodesPointers() throws {
        // ["abc", 7 (0x30 one byte? no, small), "abc" via pointer 0xA0]
        // Object list: "abc" at index 0. Pointer 0xA0 references index 0.
        let bytes = Data([0xD3, 0x43, 0x61, 0x62, 0x63, 0x09, 0xA0])
        let decoded = try OPACK.decode(bytes)
        #expect(decoded == .array([.string("abc"), .int(1), .string("abc")]))

        // Dictionary where key and value reuse: {"k": "k"} with pointer.
        let dict = Data([0xE1, 0x41, 0x6B, 0xA0])
        #expect(try OPACK.decode(dict) == .dictionary(["k": .string("k")]))

        // A sized int and a string are both in the object list. 0xA1 picks the string.
        let mixed = Data([0xD3, 0x30, 0xFF, 0x41, 0x78, 0xA1])
        #expect(try OPACK.decode(mixed) == .array([.int(255), .string("x"), .string("x")]))
    }

    @Test func opackEncoderEmitsPointersForRepeats() throws {
        let value: OPACKValue = .array([.string("repeat"), .string("repeat")])
        let encoded = OPACK.encode(value)
        #expect(encoded == Data([0xD2, 0x46] + Array("repeat".utf8) + [0xA0]))
        #expect(try OPACK.decode(encoded) == value)
    }

    @Test func opackDecodesEndlessCollections() throws {
        let bytes = Data([0xDF, 0x08, 0x09, 0x03])
        #expect(try OPACK.decode(bytes) == .array([.int(0), .int(1)]))
        let dict = Data([0xEF, 0x41, 0x61, 0x01, 0x03])
        #expect(try OPACK.decode(dict) == .dictionary(["a": .bool(true)]))
    }

    @Test func opackRejectsTruncatedInput() {
        #expect(throws: OPACKError.truncated) {
            try OPACK.decode(Data([0x45, 0x61]))
        }
        #expect(throws: OPACKError.badPointer(3)) {
            try OPACK.decode(Data([0xA3]))
        }
    }

    // MARK: TLV8

    @Test func tlv8FragmentsLongValues() throws {
        let long = Data((0..<300).map { UInt8($0 & 0xFF) })
        let encoded = TLV8.encode([(TLV8Tag.encryptedData, long), (TLV8Tag.state, Data([3]))])
        // 300 bytes become one 255-byte fragment and one 45-byte fragment.
        #expect(encoded.count == 2 + 255 + 2 + 45 + 2 + 1)
        #expect(encoded[0] == 0x05)
        #expect(encoded[1] == 255)
        #expect(encoded[257] == 0x05)
        #expect(encoded[258] == 45)
        let decoded = try TLV8.decode(encoded)
        #expect(decoded[.encryptedData] == long)
        #expect(decoded[.state] == Data([3]))
    }

    @Test func tlv8ReportsErrors() throws {
        let encoded = TLV8.encode([(TLV8Tag.state, Data([4])), (TLV8Tag.error, Data([2]))])
        let decoded = try TLV8.decode(encoded)
        #expect(TLV8.error(in: decoded) == .authentication)
        #expect(throws: TLV8DecodeError.truncated) {
            try TLV8.decode(Data([0x01, 0x05, 0x00]))
        }
    }

    // MARK: Varint

    @Test func varintVectors() throws {
        let vectors: [(UInt64, [UInt8])] = [
            (0, [0x00]),
            (1, [0x01]),
            (127, [0x7F]),
            (128, [0x80, 0x01]),
            (300, [0xAC, 0x02]),
            (UInt64.max, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]),
        ]
        for (value, bytes) in vectors {
            #expect(Varint.encode(value) == Data(bytes))
            var pos = 0
            #expect(try Varint.decode(Data(bytes), at: &pos) == value)
            #expect(pos == bytes.count)
        }
        // Decode from an offset inside a larger buffer.
        var pos = 2
        #expect(try Varint.decode(Data([0xFF, 0xFF, 0xAC, 0x02, 0x00]), at: &pos) == 300)
        #expect(pos == 4)
    }

    // MARK: Protobuf

    @Test func protobufRoundTrip() throws {
        var inner = ProtobufWriter()
        inner.string(field: 1, value: "title")
        inner.double(field: 14, value: 123.5)
        inner.bool(field: 19, value: true)
        inner.float(field: 39, value: 1.0)
        inner.int32(field: 10, value: -3)

        var outer = ProtobufWriter()
        outer.varint(field: 1, value: 4)
        outer.uint64(field: 5, value: 1_700_000_000)
        outer.message(field: 9, writer: inner)
        outer.bytes(field: 3, value: Data([9, 8, 7]))
        outer.string(field: 33, value: "a")
        outer.string(field: 33, value: "b")
        outer.int64(field: 50, value: -1)
        outer.uint32(field: 51, value: 7)

        let reader = try ProtobufReader(outer.data)
        #expect(reader.uint64(1) == 4)
        #expect(reader.uint64(5) == 1_700_000_000)
        #expect(reader.bytes(3) == Data([9, 8, 7]))
        #expect(reader.strings(33) == ["a", "b"])
        #expect(reader.int64(50) == -1)
        #expect(reader.uint32(51) == 7)
        let nested = try #require(reader.message(9))
        #expect(nested.string(1) == "title")
        #expect(nested.double(14) == 123.5)
        #expect(nested.bool(19) == true)
        #expect(nested.float(39) == 1.0)
        #expect(nested.int32(10) == -3)
        #expect(reader.messages(9).count == 1)
        #expect(reader.string(99) == nil)
    }

    @Test func protobufRejectsGroups() {
        #expect(throws: ProtobufError.unsupportedWireType(3)) {
            try ProtobufReader(Data([0x0B]))
        }
    }
}
