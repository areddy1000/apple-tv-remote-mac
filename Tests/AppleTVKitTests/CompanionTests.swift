import Foundation
import Testing
@testable import AppleTVKit

@Suite("CompanionTests")
struct CompanionTests {
    @Test func frameRoundTripAcrossSplitBuffer() throws {
        let payload = Data(repeating: 0xAB, count: 300)
        let frame = CompanionFrame(type: .eOPACK, payload: payload)
        let encoded = frame.encoded()
        #expect(encoded.count == 4 + 300)
        #expect(Array(encoded.prefix(4)) == [0x08, 0x00, 0x01, 0x2C])

        var buffer = encoded.prefix(100)
        #expect(CompanionFrame.read(from: buffer) == nil)
        buffer.append(encoded.suffix(from: 100))
        buffer.append(CompanionFrame(type: .noOp, payload: Data()).encoded())

        let first = try #require(CompanionFrame.read(from: buffer))
        #expect(first.frame == frame)
        #expect(first.header == encoded.prefix(4))
        #expect(first.consumed == encoded.count)
        buffer.removeFirst(first.consumed)
        let second = try #require(CompanionFrame.read(from: buffer))
        #expect(second.frame.type == .noOp)
        #expect(second.frame.payload.isEmpty)
    }

    @Test func unknownFrameTypeDecodesAsUnknown() throws {
        let raw = Data([0x7F, 0x00, 0x00, 0x01, 0x42])
        let read = try #require(CompanionFrame.read(from: raw))
        #expect(read.frame.type == .unknown)
        #expect(read.frame.payload == Data([0x42]))
    }

    @Test func pairingFramesStayClear() {
        #expect(CompanionFrameType.psStart.isAuth)
        #expect(CompanionFrameType.pvNext.isAuth)
        #expect(CompanionFrameType.eOPACK.isAuth == false)
    }

    @Test func identityFormatsAddressWithColons() {
        let identity = CompanionIdentity(clientID: "c", name: "Mac", model: "Mac1,1", deviceID: "7ad26a015a46")
        #expect(identity.deviceAddress == "7A:D2:6A:01:5A:46")
    }
}
