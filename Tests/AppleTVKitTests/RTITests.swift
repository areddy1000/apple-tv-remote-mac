import Foundation
import Testing
@testable import AppleTVKit

@Suite struct RTITests {
    let uuid = Data((0..<16).map { UInt8($0 + 1) })

    @Test func binaryPlistRoundTripsThroughFoundation() throws {
        let value: PlistValue = .dict([
            ("string", .string("hello")),
            ("unicode", .string("héllo wörld 🎬")),
            ("data", .data(Data([1, 2, 3]))),
            ("int", .int(42)),
            ("big", .int(70_000)),
            ("flag", .bool(true)),
            ("list", .array([.int(1), .string("two"), .bool(false)])),
            ("long", .string(String(repeating: "x", count: 300))),
        ])
        let encoded = BinaryPlist.encode(value)
        let decoded = try PropertyListSerialization.propertyList(from: encoded, format: nil)
        let dict = try #require(decoded as? [String: Any])
        #expect(dict["string"] as? String == "hello")
        #expect(dict["unicode"] as? String == "héllo wörld 🎬")
        #expect(dict["data"] as? Data == Data([1, 2, 3]))
        #expect(dict["int"] as? Int == 42)
        #expect(dict["big"] as? Int == 70_000)
        #expect(dict["flag"] as? Bool == true)
        let list = try #require(dict["list"] as? [Any])
        #expect(list.count == 3)
        #expect(list[1] as? String == "two")
        #expect((dict["long"] as? String)?.count == 300)
    }

    @Test func binaryPlistRoundTripsThroughOwnDecoder() throws {
        let value: PlistValue = .dict([
            ("uid", .uid(7)),
            ("bigUID", .uid(300)),
            ("nested", .dict([("k", .array([.data(Data([9])), .null, .real(1.5)]))])),
        ])
        let decoded = try BinaryPlist.decode(BinaryPlist.encode(value))
        #expect(decoded == value)
    }

    @Test func foundationArchivesDecodeWithOwnDecoder() throws {
        let archive = try NSKeyedArchiver.archivedData(withRootObject: ["a": 1, "b": "two"] as NSDictionary, requiringSecureCoding: false)
        let root = try BinaryPlist.decode(archive)
        #expect(root["$archiver"]?.stringValue == "NSKeyedArchiver")
        #expect(root["$top"]?["root"]?.uidValue != nil)
    }

    @Test func inputTextArchiveLayout() throws {
        let archive = RTIPayload.inputText(sessionUUID: uuid, text: "hello tv")
        let root = try BinaryPlist.decode(archive)
        #expect(root["$archiver"]?.stringValue == "RTIKeyedArchiver")
        #expect(root["$version"]?.intValue == 100_000)
        #expect(root["$top"]?["textOperations"]?.uidValue == 1)
        let objects = try #require(root["$objects"])
        #expect(objects[0]?.stringValue == "$null")
        #expect(objects[1]?["keyboardOutput"]?.uidValue == 2)
        #expect(objects[1]?["$class"]?.uidValue == 7)
        #expect(objects[1]?["targetSessionUUID"]?.uidValue == 5)
        #expect(objects[2]?["insertionText"]?.uidValue == 3)
        #expect(objects[2]?["$class"]?.uidValue == 4)
        #expect(objects[3]?.stringValue == "hello tv")
        #expect(objects[4]?["$classname"]?.stringValue == "TIKeyboardOutput")
        #expect(objects[5]?["NS.uuidbytes"]?.dataValue == uuid)
        #expect(objects[5]?["$class"]?.uidValue == 6)
        #expect(objects[6]?["$classname"]?.stringValue == "NSUUID")
        #expect(objects[7]?["$classname"]?.stringValue == "RTITextOperations")
        #expect(objects[7]?["$classes"] == .array([.string("RTITextOperations"), .string("NSObject")]))

        // Foundation reads the same archive.
        let plist = try PropertyListSerialization.propertyList(from: archive, format: nil)
        let dict = try #require(plist as? [String: Any])
        let list = try #require(dict["$objects"] as? [Any])
        #expect(list.count == 8)
        #expect(list[3] as? String == "hello tv")
    }

    @Test func clearTextArchiveLayout() throws {
        let archive = RTIPayload.clearText(sessionUUID: uuid)
        let root = try BinaryPlist.decode(archive)
        let objects = try #require(root["$objects"])
        #expect(objects[1]?["$class"]?.uidValue == 7)
        #expect(objects[1]?["targetSessionUUID"]?.uidValue == 5)
        #expect(objects[1]?["keyboardOutput"]?.uidValue == 2)
        #expect(objects[1]?["textToAssert"]?.uidValue == 4)
        #expect(objects[2]?["$class"]?.uidValue == 3)
        #expect(objects[3]?["$classname"]?.stringValue == "TIKeyboardOutput")
        #expect(objects[4]?.stringValue == "")
        #expect(objects[5]?["NS.uuidbytes"]?.dataValue == uuid)
        #expect(objects[6]?["$classname"]?.stringValue == "NSUUID")
        #expect(objects[7]?["$classname"]?.stringValue == "RTITextOperations")
    }

    @Test func sessionUUIDReadsFromTopPath() {
        // A response shaped like tvOS: $top.sessionUUID -> NSUUID object.
        let builder = KeyedArchiveBuilder(
            archiver: "NSKeyedArchiver",
            top: [("sessionUUID", 1), ("documentState", 3)],
            objects: [
                .string("$null"),
                .dict([("NS.uuidbytes", .data(uuid)), ("$class", .uid(2))]),
                .dict([("$classname", .string("NSUUID")), ("$classes", .array([.string("NSUUID"), .string("NSObject")]))]),
                .dict([("docSt", .uid(4))]),
                .dict([("contextBeforeInput", .uid(5))]),
                .string("typed so far"),
            ]
        )
        let archive = builder.encode()
        #expect(RTISession.sessionUUID(from: archive) == uuid)
        #expect(RTISession.currentText(from: archive) == "typed so far")
    }

    @Test func sessionUUIDReadsRawBytes() {
        let builder = KeyedArchiveBuilder(top: [("sessionUUID", 1)], objects: [.string("$null"), .data(uuid)])
        #expect(RTISession.sessionUUID(from: builder.encode()) == uuid)
    }

    @Test func sessionUUIDReturnsNilForGarbage() {
        #expect(RTISession.sessionUUID(from: Data([1, 2, 3])) == nil)
    }
}
