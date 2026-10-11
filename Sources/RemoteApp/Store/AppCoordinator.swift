import AppleTVKit
import Foundation
import Observation

/// Wires discovery, pairing and the controller to the store.
/// Set ATV_MOCK=1 in the environment to run on the mock device.
@MainActor
@Observable
final class AppCoordinator {
    let store: DeviceStore
    private let browser = DeviceBrowser()
    private let credentials = CredentialStore()
    private let identity: CompanionIdentity
    private var browseTask: Task<Void, Never>?
    private var pinContinuation: CheckedContinuation<String?, Never>?
    private var controllers: [String: AppleTVDevice] = [:]

    private static let lastDeviceKey = "atv.lastDevice"

    init(store: DeviceStore) {
        self.store = store
        self.identity = CompanionIdentity.thisMac(clientID: CredentialStore.clientID())
    }

    func start() {
        if ProcessInfo.processInfo.environment["ATV_MOCK"] == "1" {
            store.attach(MockController(), name: "Mock Apple TV")
            return
        }
        Task { try? await credentials.load() }
        browseTask = Task { [weak self] in
            guard let self else { return }
            await self.browser.start()
            for await devices in self.browser.devices {
                self.store.devices = devices
                self.autoSelect()
                // Endpoints can arrive after the first sighting. Pass the fresh record on.
                for device in devices {
                    if let controller = self.controllers[device.id] {
                        Task { await controller.update(device: device) }
                    }
                }
            }
        }
    }

    /// Picks the last used device, else the first found.
    private func autoSelect() {
        guard store.selectedDeviceID == nil, !store.devices.isEmpty else { return }
        let lastUsed = UserDefaults.standard.string(forKey: Self.lastDeviceKey)
        if let device = store.devices.first(where: { $0.id == lastUsed }) ?? store.devices.first {
            select(device)
        }
    }

    func select(_ device: DiscoveredDevice) {
        guard device.id != store.selectedDeviceID || store.controller == nil else { return }
        ATVLog.companion.info("selected \(device.name, privacy: .public)")
        UserDefaults.standard.set(device.id, forKey: Self.lastDeviceKey)
        let controller = controllers[device.id] ?? AppleTVDevice(
            device: device,
            identity: identity,
            store: credentials,
            pinProvider: { [weak self] title in
                guard let self else { return nil }
                return await self.requestPIN(title: title)
            }
        )
        controllers[device.id] = controller
        store.attach(controller, name: device.name)
    }

    /// Removes the stored pairing for the selected TV and connects again, which asks for a PIN.
    func forgetSelected() {
        guard let id = store.selectedDeviceID, let controller = controllers[id] else { return }
        Task {
            await controller.forget()
            controllers[id] = nil
            store.connection = .idle
            if let device = store.devices.first(where: { $0.id == id }) {
                store.selectedDeviceID = nil
                select(device)
            }
        }
    }

    /// Pairs the selected Apple TV. The PIN sheet lives in the window, so it opens first.
    func pairSelected() {
        guard let id = store.selectedDeviceID, let controller = controllers[id] else { return }
        RemoteApp.summon()
        Task { await controller.pair() }
    }

    func wakeSelected() {
        guard let id = store.selectedDeviceID, let controller = controllers[id] else { return }
        Task { await controller.wake() }
    }

    /// Waits for the user to type the PIN. Returns nil on cancel.
    func requestPIN(title: String) async -> String? {
        store.pinEntry = ""
        store.pairingTitle = title
        store.connection = .awaitingPIN
        return await withCheckedContinuation { continuation in
            pinContinuation = continuation
        }
    }

    func submitPIN() {
        guard store.pinEntry.count == 4 else { return }
        let pin = store.pinEntry
        store.connection = .pairing
        pinContinuation?.resume(returning: pin)
        pinContinuation = nil
    }

    func cancelPairing() {
        store.connection = .idle
        pinContinuation?.resume(returning: nil)
        pinContinuation = nil
    }
}
