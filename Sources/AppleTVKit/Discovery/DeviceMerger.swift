import Foundation
import Network

/// One Bonjour service result before the merge.
struct ServiceRecord: Sendable {
    /// The Bonjour instance name.
    var name: String
    /// The parsed TXT record.
    var txt: [String: String]
    var endpoint: NWEndpoint?

    init(name: String, txt: [String: String], endpoint: NWEndpoint? = nil) {
        self.name = name
        self.txt = txt
        self.endpoint = endpoint
    }
}

/// Joins Companion and AirPlay results into one device list.
/// The join key is AirPlay `psi` equal to Companion `rpMRtID`.
/// The fallback join key is the instance name.
enum DeviceMerger {
    static func merge(
        companion: [String: ServiceRecord],
        airplay: [String: ServiceRecord]
    ) -> [DiscoveredDevice] {
        var devices: [String: DiscoveredDevice] = [:]
        var usedAirPlayNames = Set<String>()

        for record in companion.values {
            let joinID = record.txt["rpMRtID"]
            let partner = airplay.values.first { candidate in
                if let joinID, let psi = candidate.txt["psi"], psi == joinID { return true }
                return candidate.name == record.name
            }
            if let partner { usedAirPlayNames.insert(partner.name) }

            let id = joinID ?? partner?.txt["psi"] ?? record.name
            var device = DiscoveredDevice(id: id, name: record.name)
            apply(companion: record, to: &device)
            if let partner { apply(airplay: partner, to: &device) }
            devices[id] = device
        }

        for record in airplay.values where !usedAirPlayNames.contains(record.name) {
            let id = record.txt["psi"] ?? record.name
            var device = devices[id] ?? DiscoveredDevice(id: id, name: record.name)
            apply(airplay: record, to: &device)
            devices[id] = device
        }

        return devices.values
            .filter(\.isAppleTV)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func apply(companion record: ServiceRecord, to device: inout DiscoveredDevice) {
        device.companionEndpoint = record.endpoint
        if let model = record.txt["rpMd"] {
            device.model = model
            device.isAppleTV = device.isAppleTV || model.hasPrefix("AppleTV")
        }
    }

    private static func apply(airplay record: ServiceRecord, to device: inout DiscoveredDevice) {
        device.airplayEndpoint = record.endpoint
        if let model = record.txt["model"] {
            device.model = model
            device.isAppleTV = device.isAppleTV || model.hasPrefix("AppleTV")
        }
        if let mac = record.txt["deviceid"] { device.macAddress = mac }
        if let os = record.txt["osvers"] { device.osVersion = os }
    }
}
