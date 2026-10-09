import Foundation
import Testing
@testable import AppleTVKit

@Suite struct DiscoveryTests {
    @Test func rawTXTParsesPairs() {
        var raw = Data()
        for entry in ["rpMd=AppleTV14,1", "rpFl=0x36782", "flag"] {
            raw.append(UInt8(entry.utf8.count))
            raw.append(contentsOf: Array(entry.utf8))
        }
        let txt = TXTRecord.parse(raw: raw)
        #expect(txt["rpMd"] == "AppleTV14,1")
        #expect(txt["rpFl"] == "0x36782")
        #expect(txt["flag"] == "")
    }

    @Test func mergeJoinsByPSI() {
        let companion = [
            "Living Room": ServiceRecord(name: "Living Room", txt: [
                "rpMd": "AppleTV14,1",
                "rpMRtID": "57BB045C-3E7D-4E6D-B345-CB3844A9968B",
            ]),
            "MacBook Pro (2)": ServiceRecord(name: "MacBook Pro (2)", txt: ["rpMd": "MacBookPro18,1"]),
        ]
        let airplay = [
            "Living Room": ServiceRecord(name: "Living Room", txt: [
                "model": "AppleTV14,1",
                "psi": "57BB045C-3E7D-4E6D-B345-CB3844A9968B",
                "deviceid": "56:BB:04:5C:3E:7D",
                "osvers": "26.6",
            ]),
            "MacBook Pro (2)": ServiceRecord(name: "MacBook Pro (2)", txt: ["model": "MacBookPro18,1"]),
        ]
        let devices = DeviceMerger.merge(companion: companion, airplay: airplay)
        #expect(devices.count == 1)
        let device = try! #require(devices.first)
        #expect(device.id == "57BB045C-3E7D-4E6D-B345-CB3844A9968B")
        #expect(device.name == "Living Room")
        #expect(device.model == "AppleTV14,1")
        #expect(device.modelDisplayName == "Apple TV 4K (3rd gen)")
        #expect(device.macAddress == "56:BB:04:5C:3E:7D")
        #expect(device.osVersion == "26.6")
        #expect(device.isAppleTV)
    }

    @Test func mergeFallsBackToName() {
        let companion = ["Bedroom": ServiceRecord(name: "Bedroom", txt: ["rpMd": "AppleTV6,2"])]
        let airplay = ["Bedroom": ServiceRecord(name: "Bedroom", txt: ["model": "AppleTV6,2", "deviceid": "AA:BB:CC:DD:EE:FF"])]
        let devices = DeviceMerger.merge(companion: companion, airplay: airplay)
        #expect(devices.count == 1)
        #expect(devices.first?.id == "Bedroom")
        #expect(devices.first?.macAddress == "AA:BB:CC:DD:EE:FF")
    }

    @Test func mergeKeepsAirPlayOnlyAppleTV() {
        let airplay = ["Office": ServiceRecord(name: "Office", txt: ["model": "AppleTV5,3", "psi": "X"])]
        let devices = DeviceMerger.merge(companion: [:], airplay: airplay)
        #expect(devices.count == 1)
        #expect(devices.first?.modelDisplayName == "Apple TV HD")
        #expect(devices.first?.companionEndpoint == nil)
    }

    @Test func mergeSortsByName() {
        let companion = [
            "Zebra": ServiceRecord(name: "Zebra", txt: ["rpMd": "AppleTV14,1", "rpMRtID": "2"]),
            "alpha": ServiceRecord(name: "alpha", txt: ["rpMd": "AppleTV14,1", "rpMRtID": "1"]),
        ]
        let devices = DeviceMerger.merge(companion: companion, airplay: [:])
        #expect(devices.map(\.name) == ["alpha", "Zebra"])
    }

    @Test func magicPacketLayout() throws {
        let packet = try WakeOnLAN.magicPacket(mac: "56:BB:04:5C:3E:7D")
        #expect(packet.count == 6 + 16 * 6)
        #expect(packet.prefix(6) == Data(repeating: 0xFF, count: 6))
        #expect(Array(packet[6..<12]) == [0x56, 0xBB, 0x04, 0x5C, 0x3E, 0x7D])
        #expect(Array(packet.suffix(6)) == [0x56, 0xBB, 0x04, 0x5C, 0x3E, 0x7D])
        #expect(throws: WakeOnLAN.WakeError.self) { try WakeOnLAN.magicPacket(mac: "nope") }
    }
}
