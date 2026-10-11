import Foundation
import Testing
@testable import AppleTVKit

@Suite struct DiscoveryTests {
    /// Synthetic identifiers. They look like the TXT records but belong to no real device.
    private static let joinID = "11111111-2222-3333-4444-555555555555"
    private static let mac = "02:00:00:00:00:01"

    @Test func mergeJoinsByPSI() throws {
        let companion = [
            "Living Room": ServiceRecord(name: "Living Room", txt: [
                "rpMd": "AppleTV14,1",
                "rpMRtID": Self.joinID,
            ]),
            "Office Mac": ServiceRecord(name: "Office Mac", txt: ["rpMd": "MacBookPro18,1"]),
        ]
        let airplay = [
            "Living Room": ServiceRecord(name: "Living Room", txt: [
                "model": "AppleTV14,1",
                "psi": Self.joinID,
                "deviceid": Self.mac,
                "osvers": "26.6",
            ]),
            "Office Mac": ServiceRecord(name: "Office Mac", txt: ["model": "MacBookPro18,1"]),
        ]
        let devices = DeviceMerger.merge(companion: companion, airplay: airplay)
        #expect(devices.count == 1)
        let device = try #require(devices.first)
        #expect(device.id == Self.joinID)
        #expect(device.name == "Living Room")
        #expect(device.model == "AppleTV14,1")
        #expect(device.modelDisplayName == "Apple TV 4K (3rd gen)")
        #expect(device.macAddress == Self.mac)
        #expect(device.osVersion == "26.6")
        #expect(device.isAppleTV)
    }

    @Test func mergeFallsBackToName() {
        let companion = ["Bedroom": ServiceRecord(name: "Bedroom", txt: ["rpMd": "AppleTV6,2"])]
        let airplay = ["Bedroom": ServiceRecord(name: "Bedroom", txt: ["model": "AppleTV6,2", "deviceid": Self.mac])]
        let devices = DeviceMerger.merge(companion: companion, airplay: airplay)
        #expect(devices.count == 1)
        #expect(devices.first?.id == "Bedroom")
        #expect(devices.first?.macAddress == Self.mac)
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
        let packet = try WakeOnLAN.magicPacket(mac: Self.mac)
        let address: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01]
        #expect(packet.count == 6 + 16 * 6)
        #expect(packet.prefix(6) == Data(repeating: 0xFF, count: 6))
        #expect(Array(packet[6..<12]) == address)
        #expect(Array(packet.suffix(6)) == address)
        #expect(try WakeOnLAN.magicPacket(mac: "02-00-00-00-00-01") == packet)
        #expect(throws: WakeOnLAN.WakeError.self) { try WakeOnLAN.magicPacket(mac: "nope") }
    }

    /// The app skips a Bonjour update that changes nothing. A changed record must not look
    /// the same, or the app keeps an old endpoint.
    @Test func aChangedRecordIsNotEqual() {
        let first = DiscoveredDevice(id: "a", name: "Living Room")
        var moved = first
        moved.airplayEndpoint = .service(name: "Living Room", type: "_airplay._tcp", domain: "local.", interface: nil)
        var renamed = first
        renamed.name = "Den"
        #expect(first == first)
        #expect(first != moved)
        #expect(first != renamed)
        // One device keeps one hash, so a set still finds it after a change.
        #expect(first.hashValue == moved.hashValue)
    }
}
