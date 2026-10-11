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
    /// The stored records, for the device list.
    private var stored: [String: StoredDevice] = [:]
    /// The app connects by itself one time, at launch, and only to a paired Apple TV.
    private var launchConnectDone = false

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
        browseTask = Task { [weak self] in
            guard let self else { return }
            // The launch connection needs to know which Apple TVs are paired, so load first.
            try? await self.credentials.load()
            await self.refreshKnown()
            await self.browser.start()
            for await devices in self.browser.devices {
                // Bonjour reports often with no change. Each write makes the UI draw again.
                guard devices != self.store.devices else { continue }
                let old = Dictionary(self.store.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.store.devices = devices
                self.publishKnown()
                self.connectAtLaunch()
                // Endpoints can arrive after the first sighting. Pass a changed record on.
                for device in devices where old[device.id] != device {
                    if let controller = self.controllers[device.id] {
                        Task { await controller.update(device: device) }
                    }
                }
            }
        }
    }

    /// Reads the stored records again and updates the device list.
    func refreshKnown() async {
        stored = (try? await credentials.allDevices()) ?? [:]
        publishKnown()
    }

    private func publishKnown() {
        let known = KnownDevice.merge(discovered: store.devices, stored: stored)
        if known != store.knownDevices { store.knownDevices = known }
    }

    /// Connects one time at launch to a paired Apple TV: the last used one, else the first.
    /// An Apple TV with no pairing never connects by itself, because a PIN turns the television on.
    private func connectAtLaunch() {
        guard !launchConnectDone, store.selectedDeviceID == nil else { return }
        let paired = store.devices.filter { stored[$0.id]?.companion != nil }
        guard !paired.isEmpty else { return }
        launchConnectDone = true
        let lastUsed = UserDefaults.standard.string(forKey: Self.lastDeviceKey)
        if let device = paired.first(where: { $0.id == lastUsed }) ?? paired.first {
            select(device)
        }
    }

    /// Connects to a device from the list. It never asks for a PIN.
    func connect(id: String) {
        guard let device = store.devices.first(where: { $0.id == id }) else { return }
        select(device)
    }

    /// Pairs a device from the list. The Apple TV shows a PIN, and the panel asks for it.
    func pair(id: String) {
        guard let device = store.devices.first(where: { $0.id == id }) else { return }
        dropControllers(except: device.id)
        let controller = controller(for: device)
        store.attach(controller, name: device.name, connect: false)
        UserDefaults.standard.set(device.id, forKey: Self.lastDeviceKey)
        Task { await controller.pair() }
    }

    /// Ends the link and goes back to the device list.
    func disconnect() {
        store.detach()
        dropControllers(except: nil)
    }

    /// Shuts down and forgets every controller but one. Only one Apple TV is in use at a time.
    /// A controller that stays in the table keeps its loops and its memory.
    private func dropControllers(except keep: String?) {
        for (id, controller) in controllers where id != keep {
            controllers[id] = nil
            Task { await controller.shutdown() }
        }
    }

    func select(_ device: DiscoveredDevice) {
        if device.id == store.selectedDeviceID, let controller = store.controller {
            // The same Apple TV after a failure: try again on the attached controller.
            if !store.connection.isConnected, !store.connection.isBusy {
                Task { await controller.connect() }
            }
            return
        }
        ATVLog.companion.info("selected \(device.name, privacy: .public)")
        UserDefaults.standard.set(device.id, forKey: Self.lastDeviceKey)
        dropControllers(except: device.id)
        store.attach(controller(for: device), name: device.name)
    }

    private func controller(for device: DiscoveredDevice) -> AppleTVDevice {
        if let controller = controllers[device.id] { return controller }
        let controller = AppleTVDevice(
            device: device,
            identity: identity,
            store: credentials,
            pinProvider: { [weak self] title in
                guard let self else { return nil }
                return await self.requestPIN(title: title)
            }
        )
        controllers[device.id] = controller
        return controller
    }

    /// Removes the stored pairing for the selected TV and goes back to the device list.
    func forgetSelected() {
        guard let id = store.selectedDeviceID, let controller = controllers[id] else { return }
        store.detach()
        controllers[id] = nil
        Task {
            await controller.forget()
            await controller.shutdown()
            await refreshKnown()
        }
    }

    /// Pairs the selected Apple TV. The PIN entry lives in the menu bar panel, so it opens first.
    func pairSelected() {
        guard let id = store.selectedDeviceID, let controller = controllers[id] else { return }
        MenuBarPanelOpener.open()
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
