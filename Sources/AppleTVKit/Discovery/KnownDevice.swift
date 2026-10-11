import Foundation

/// One row of the device list: an Apple TV on the network now, paired or not.
public struct KnownDevice: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// On the network, with a stored pairing key.
        case paired
        /// On the network, with no pairing key.
        case notPaired
    }

    public let id: String
    public let name: String
    /// A human model name, for example "Apple TV 4K (3rd gen)".
    public let model: String
    public let state: State

    public init(id: String, name: String, model: String, state: State) {
        self.id = id
        self.name = name
        self.model = model
        self.state = state
    }

    /// Lists the devices on the network, marks the paired ones, and sorts them by name.
    /// An Apple TV that is not on the network is left out, even when it was paired before.
    public static func merge(discovered: [DiscoveredDevice], stored: [String: StoredDevice]) -> [KnownDevice] {
        discovered.map { device in
            KnownDevice(
                id: device.id,
                name: device.name,
                model: device.modelDisplayName,
                state: stored[device.id]?.companion != nil ? .paired : .notPaired
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
