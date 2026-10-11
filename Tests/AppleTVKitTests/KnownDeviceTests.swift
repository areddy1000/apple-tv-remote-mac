import Foundation
import Testing
@testable import AppleTVKit

/// The device list shows the Apple TVs on the network now, and marks the paired ones.
@Suite("KnownDeviceTests")
struct KnownDeviceTests {
    let creds = HAPCredentials(ltpk: Data([1]), ltsk: Data([2]), accessoryID: Data([3]), clientID: Data([4]))

    @Test func aFoundPairedTVIsPaired() {
        let found = DiscoveredDevice(id: "a", name: "Living Room", model: "AppleTV14,1", isAppleTV: true)
        let list = KnownDevice.merge(discovered: [found], stored: ["a": StoredDevice(name: "Living Room", companion: creds)])
        #expect(list == [KnownDevice(id: "a", name: "Living Room", model: "Apple TV 4K (3rd gen)", state: .paired)])
    }

    @Test func aFoundTVWithoutAKeyIsNotPaired() {
        let found = DiscoveredDevice(id: "a", name: "Living Room", isAppleTV: true)
        // The file keeps the name and the MAC address after the key is gone.
        let list = KnownDevice.merge(discovered: [found], stored: ["a": StoredDevice(name: "Living Room", macAddress: "02:00")])
        #expect(list.map(\.state) == [.notPaired])
    }

    // The list shows only Apple TVs on the network now, never ones that were paired before.
    @Test func anAwayTVIsLeftOut() {
        let list = KnownDevice.merge(discovered: [], stored: [
            "b": StoredDevice(name: "Bedroom", companion: creds),
            "c": StoredDevice(name: "Office"),
        ])
        #expect(list.isEmpty)
    }

    @Test func theListIsSortedByName() {
        let list = KnownDevice.merge(
            discovered: [DiscoveredDevice(id: "z", name: "Office"), DiscoveredDevice(id: "y", name: "Den")],
            stored: [:]
        )
        #expect(list.map(\.name) == ["Den", "Office"])
    }

    @Test func storeListsAllDevices() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("atv-all-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CredentialStore(directory: directory)
        try await store.save(StoredDevice(name: "Living Room", companion: creds), for: "a")
        try await store.save(StoredDevice(name: "Bedroom"), for: "b")
        let all = try await CredentialStore(directory: directory).allDevices()
        #expect(Set(all.keys) == ["a", "b"])
        #expect(all["a"]?.companion == creds)
    }
}
