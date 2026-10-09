import Foundation
import Network

/// One Apple TV found on the local network.
/// The Companion and AirPlay services of one box merge into one value.
public struct DiscoveredDevice: Identifiable, Sendable {
    /// The shared identifier. AirPlay `psi` equals Companion `rpMRtID`.
    /// The Bonjour instance name is the fallback.
    public var id: String
    /// The Bonjour instance name, for example "Living Room".
    public var name: String
    /// The hardware model, for example "AppleTV14,1".
    public var model: String?
    /// The MAC address from the AirPlay `deviceid` record. Wake-on-LAN uses it.
    public var macAddress: String?
    /// The tvOS version from the AirPlay `osvers` record.
    public var osVersion: String?
    public var companionEndpoint: NWEndpoint?
    public var airplayEndpoint: NWEndpoint?
    /// True when a model record starts with "AppleTV".
    public var isAppleTV: Bool

    init(
        id: String,
        name: String,
        model: String? = nil,
        macAddress: String? = nil,
        osVersion: String? = nil,
        companionEndpoint: NWEndpoint? = nil,
        airplayEndpoint: NWEndpoint? = nil,
        isAppleTV: Bool = false
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.macAddress = macAddress
        self.osVersion = osVersion
        self.companionEndpoint = companionEndpoint
        self.airplayEndpoint = airplayEndpoint
        self.isAppleTV = isAppleTV
    }

    /// A human name for the model.
    public var modelDisplayName: String {
        Self.displayName(forModel: model)
    }

    /// Maps a model code to a human name.
    public static func displayName(forModel model: String?) -> String {
        switch model {
        case "AppleTV5,3": return "Apple TV HD"
        case "AppleTV6,2": return "Apple TV 4K"
        case "AppleTV11,1": return "Apple TV 4K (2nd gen)"
        case "AppleTV14,1": return "Apple TV 4K (3rd gen)"
        default: return "Apple TV"
        }
    }
}

extension DiscoveredDevice: Equatable, Hashable {
    public static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
