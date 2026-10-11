import Foundation

/// One row of the device list: an Apple TV on the network, a paired one, or both.
public struct KnownDevice: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// On the network, with a stored pairing key.
        case paired
        /// On the network, with no pairing key.
        case notPaired
        /// Paired before, but not on the network now.
        case notOnNetwork
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

    /// Merges the devices on the network with the stored records, sorted by name.
    /// A stored record without a key and off the network is left out, because nothing can use it.
    public static func merge(discovered: [DiscoveredDevice], stored: [String: StoredDevice]) -> [KnownDevice] {
        var list = discovered.map { device in
            KnownDevice(
                id: device.id,
                name: device.name,
                model: device.modelDisplayName,
                state: stored[device.id]?.companion != nil ? .paired : .notPaired
            )
        }
        let found = Set(discovered.map(\.id))
        for (id, record) in stored where record.companion != nil && !found.contains(id) {
            list.append(KnownDevice(id: id, name: record.name, model: DiscoveredDevice.displayName(forModel: nil),
                                    state: .notOnNetwork))
        }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
